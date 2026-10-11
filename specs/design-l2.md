# Design L2 — Family Contacts Unify

Feature: `family-contacts-unify` (worktree branch `feat/family-contacts-unify`, worktree
`elderly-ai-assistant-family-contacts-unify`; base master `8089c735`).
Task: `design-l2`, agent `principal-engineer`, contract `component_design_l2`.
Date: 2026-10-12.
Revision: rev 3 (2026-10-12) — review iteration-2 residual R4 applied: the fifth access
consumer `AppCoordinator.refreshNativeMissedCallNames` (:8327-8358) added to the §3.5
enumeration with its fix spec (:8336 status re-read, :8338 `allowsReading` guard, :8346 real
`access:` passthrough) and pinned (§8.2, §6.4, §8.3).
Revision: rev 2 (2026-10-12) — review-l2 NO_GO rework applied: R1 `.limited` gates
(§2.2, §3.5, §8.2, §9 R2); R2 drain-loop coalescing (§4.2, §3.6); R3 contiguity pin
(§7); minors (§1.7, §2.2, §8.2).
Status: elaboration of the FROZEN `specs/design-l1.md` — nothing here redesigns L1; every
section resolves an L1 §19 deferral or fixes a component-level detail L1 left to L2.

Inputs read: `specs/design-l1.md` (frozen architecture — the source of truth),
`specs/define-requirements.md` + `FR/`/`NFR/` (locked set), `specs/family-contacts-unify/constitution.md`,
project `constitution.md`, and verified code anchors at base master `8089c735` (file:line
references below were re-read in this worktree).

## 0. L1 §19 deferral checklist (this document's binding scope)

| L1 §19 deferral | Resolved in |
|---|---|
| Wizard sheet restructure (state flow, subviews), coordinator's new methods, exact placement of `normalizedNicknames` | §1.9, §2, §3.4, §8.2 |
| Final en/ne wording for the §12 keys | §7 |
| `SystemContactLinkService.photoImageData` cache constants; worker's retry-free sequencing around refresh epochs | §4.3, §4.4 |
| Already-linked steering micro-flow (tap targets, back-navigation) | §2.3 |
| `contactPhoto(for:)` delete vs retain | §8.1 |
| Verification scheduling (launch/foreground hook ordering); a11y labels per control | §4.4, §2.5, §7 |
| Unit/task decomposition and wave ordering | out of scope — `plan-tasks` follows approval |

Deviations from L1 sketches (interface-shape only, intent identical; flagged for the reviewer):

1. `SystemContactLinkReading.invalidate(identifier:)` is `async` in L2. An actor method cannot
   satisfy a synchronous protocol requirement while touching actor state; the marker is
   technically required for `SystemContactLinkService: SystemContactLinkReading`.
2. L1 §9.3's second pure mapping is expressed as
   `SystemContactWriteAccess.from(_ access: ContactsAccess)` over the ALREADY-mapped
   `ContactsAccess` (which owns the single `#available(iOS 18)` gate) instead of a second
   availability-gated switch over `CNAuthorizationStatus`. Same behavior table, one gate.
3. L1 §9.2's `mutableCopy() as! CNMutableContact` becomes a checked `as?` cast that maps to
   `.failed(.saveRejected)` with a DEBUG `assertionFailure` — the write seam may not crash
   (§10.1 no-crash rule) even on a platform change.
4. L1 §10.2's "primary button to Done" uses the EXISTING key `common.close` (en "Close", ne
   "बन्द गर्नुहोस्") — verified present in the catalog; zero new keys beyond the frozen 21.

## 1. Component interfaces and contracts

All signatures are final unless a line is marked `(internal)`. Every interface declares its
normal return AND its error/outcome type; none returns `any`/`unknown` error shapes, none
throws across a seam that a UI path consumes.

### 1.1 `SystemContactLink` — FamilyContactStore.swift

```swift
/// A pointer to one record in the system address book, with the fingerprint
/// needed to prove it is still the same person. Local-only; never transmitted.
/// Defined next to `FamilyContact` because it is part of the persisted payload
/// shape the decoder reads in the same file.
struct SystemContactLink: Codable, Equatable {
    var identifier: String   // CNContact.identifier at link time
    var numberKey: String    // ContactNumberKey.normalized of the FIRST dialable
                             // number of the picked entry at link time
}
```

Error contract: none (pure value). Corrupt persistence is handled at decode (§3.4): an empty
`identifier` or `numberKey` decodes to `nil` — "unlinked", never a crash (FR-FCU-002 scenario 3).

### 1.2 `FamilyContactIndex` — new file `Services/Contacts/FamilyContactIndex.swift`

```swift
/// Derived, value-type index over the family roster (L1 §5.4). Rebuilt wholesale on
/// every roster publish; never persisted; never mutated in place.
struct FamilyContactIndex: Equatable {
    struct Entry: Equatable {
        let id: UUID
        let normalizedName: String         // NepaliTextNormalizer.normalize(name)
        let normalizedNicknames: [String]  // per entry, order preserved (normalizedNicknames applied)
        let rawNicknames: [String]         // stored spellings, order preserved (containment parity)
    }

    private(set) var entries: [Entry]                  // roster order preserved
    private(set) var idsByNickname: [String: [UUID]]   // normalized exact key → ids, roster order

    init(family: [FamilyContact])
    static let empty = FamilyContactIndex(family: [])   // == today's behavior anchor

    func nicknameEntries(for id: UUID) -> [String]     // normalized nicknames of one contact
    func exactNicknameHolders(_ normalizedQuery: String) -> [UUID]  // O(1) map hit
    func entry(for id: UUID) -> Entry?                 // hot-path lookup for ContactResolver
}
```

Isolation: pure value, no shared mutable state, safe on any thread (L1 §13.1). Empty index
reproduces today's name-only behavior byte-for-byte (L1 §5.4, compatibility anchor).

### 1.3 Link verification — new file `Services/Contacts/SystemContactLinkService.swift`

```swift
/// Published snapshot of VERIFIED links (L1 §6.2). `.empty` ⇒ unlinked semantics.
struct VerifiedLinksSnapshot: Equatable {
    var links: [UUID: SystemContactLink]           // verified only
    var linkedRecordNumbers: [String: [String]]    // identifier → current normalized numbers
    var generation: UInt64                         // bumps once per COMPLETED fetch

    static let empty = VerifiedLinksSnapshot(links: [:], linkedRecordNumbers: [:], generation: 0)

    /// The family contact id whose verified link points at `identifier`, or nil
    /// (unique by L1 §6.2; duplicate stored claims were dropped at verification).
    func familyID(forIdentifier identifier: String) -> UUID?
    /// The family contact id whose linked record carries a number matching `phone`
    /// (MissedCallContactResolver.matches trailing-digit rule, reused unchanged).
    func familyID(matchingRecordNumber phone: String) -> UUID?
}

/// The narrow platform seam both new services share — fakeable in tests
/// (CNContactStore is not constructible or fakeable in unit tests).
protocol SystemContactReading: AnyObject {
    func currentAccess() -> ContactsAccess
    /// Records matching `identifiers`, under the CURRENT access. A withheld
    /// record is simply absent (limited access). Throws on store-level failure.
    func contacts(identifiers: [String], keysToFetch: [CNKeyDescriptor]) throws -> [CNContact]
}

protocol SystemContactLinkReading: AnyObject {
    func refresh(contacts: [FamilyContact]) async -> VerifiedLinksSnapshot
    func photoImageData(forIdentifier identifier: String) async -> Data?   // nil: absent/unreadable
    func invalidate(identifier: String?)                                    // one record, or all
}

/// actor: all state below is actor-isolated (L1 §13.1).
actor SystemContactLinkService: SystemContactLinkReading {
    init(reader: SystemContactReading = AddressBookDirectory(),
         observabilityBus: ObservabilityBus? = nil)

    /// ONE batched fetch (≤12 identifiers; keys [identifier, phoneNumbers]).
    /// - fetch throws            → previous snapshot returned unchanged (degraded, reason-coded)
    /// - per-link: verified iff the record exists AND any current normalized number
    ///   satisfies MissedCallContactResolver.matches(storedNumberKey, current)
    /// - duplicate identifier claims: first in ROSTER order wins; later ones unverified
    /// - access not readable (.denied/.notDetermined) → NO store call, snapshot unchanged
    func refresh(contacts: [FamilyContact]) async -> VerifiedLinksSnapshot

    /// System photo bytes keyed by identifier; nil when absent/unreadable/not readable.
    func photoImageData(forIdentifier identifier: String) async -> Data?

    /// One identifier or the whole photo cache (nil = all).
    func invalidate(identifier: String?)
}
```

Isolation and cache: the photo-byte cache is `NSCache<NSString, NSData>` INSIDE the actor
(constants in §4.3), so the actor is the only mutator; concurrent callers await serialized
access. `AddressBookDirectory` conforms:

```swift
extension AddressBookDirectory: SystemContactReading {
    func currentAccess() -> ContactsAccess { Self.access() }
    func contacts(identifiers: [String], keysToFetch: [CNKeyDescriptor]) throws -> [CNContact] {
        let predicate = CNContact.predicateForContacts(withIdentifiers: identifiers)
        return try store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)
    }
}
```

(Placed in AddressBookDirectory.swift; the store stays private.)

### 1.4 Write seam — new file `Services/Contacts/SystemContactPhotoWriter.swift`

```swift
enum SystemContactWriteAccess: Equatable {
    case notDetermined, denied, limited, full

    /// Pure mapping from the already-mapped read access (single iOS-18 gate lives
    /// in `ContactsAccess.from`). `.allowed → .full`, `.limited → .limited`.
    static func from(_ access: ContactsAccess) -> SystemContactWriteAccess
}

enum SystemContactWriteFailure: String, Equatable {   // raw values ARE the log reason codes
    case fetchFailed = "fetch_failed"
    case notInGrantedSelection = "not_in_granted_selection"
    case saveRejected = "save_rejected"
    case readBackMismatch = "read_back_mismatch"
}

enum SystemContactPhotoWriteOutcome: Equatable {
    case written                                   // saved AND verified by read-back
    case skippedNoLink                             // unlinked/unverified → no attempt (today's behavior)
    case skippedNoAuthorization(SystemContactWriteAccess)
    case recordGone                                // identifier no longer resolves
    case identityMismatch                          // fingerprint failed at attempt time
    case failed(SystemContactWriteFailure)

    /// Closed log vocabulary (observability only — never user-visible).
    var logToken: String
}

protocol SystemContactPhotoWriting: AnyObject {
    func writeAccess() async -> SystemContactWriteAccess                // detected, never assumed
    func writePhoto(_ jpeg: Data, to link: SystemContactLink) async -> SystemContactPhotoWriteOutcome
    func clearPhoto(from link: SystemContactLink) async -> SystemContactPhotoWriteOutcome
}

/// The confined real glue (L1 §9.2). The ONLY file in the tree permitted to
/// construct CNSaveRequest / CNMutableContact (pinned by a source-scan test, §6.4).
actor SystemContactPhotoWriter: SystemContactPhotoWriting {
    init(store: CNContactStore = CNContactStore(), observabilityBus: ObservabilityBus? = nil)
}
```

Attempt sequence inside `writePhoto`/`clearPhoto` (exact):
1. Fetch by identifier, keys `[CNContactIdentifierKey, CNContactPhoneNumbersKey,
   CNContactImageDataKey, CNContactImageDataAvailableKey]` via
   `unifiedContacts(matching: CNContact.predicateForContacts(withIdentifiers:))`.
   - throw + access `.limited` → `.failed(.notInGrantedSelection)`; throw otherwise → `.failed(.fetchFailed)`
   - empty + `.limited` → `.failed(.notInGrantedSelection)`; empty otherwise → `.recordGone`
2. Fingerprint re-check AT ATTEMPT TIME: the record's current numbers must contain one
   matching `link.numberKey` (`MissedCallContactResolver.matches`). No match, or no numbers at
   all → `.identityMismatch` — the wrong-contact write is PREVENTED, not detected.
3. Build `PhotoWriteIntent { identifier, numberKey, fields: Set<PhotoWriteField> }` where
   `enum PhotoWriteField { case photo }` — the invariant is `fields == [.photo]`; DEBUG
   `assert(intent.fields == [.photo])`. `mutable = contact.mutableCopy()` checked-cast (see
   deviation 3); assign ONLY `imageData` (`clearPhoto`: `imageData = nil`); `CNSaveRequest().update(mutable)`;
   `try request.execute(store)` in do/catch → `.failed(.saveRejected)`.
4. Read-back: re-fetch `CNContactImageDataKey`; byte equality with the written JPEG →
   `.written`; anything else → `.failed(.readBackMismatch)` (never a false success).
5. Serialization: actor isolation makes saves strictly serial (L1 §13.2). No retries, no
   backoff, no timeouts (§4.5).

### 1.5 Outcome→UI mapping — total by construction

```swift
/// The editor's photo outcome states (consumed by the wizard, §2.4).
enum FamilyPhotoEditorState: Equatable {
    case updatedInSystem                          // family.photo.state.updatedInSystem
    case keptOnPhone                              // family.photo.state.keptOnPhone
    case keptOnPhoneAccessDenied                  // keptOnPhone + family.photo.accessDeniedBody
    case systemPhotoRemains                       // family.photo.state.systemPhotoRemains

    /// TOTAL mapping from every write outcome; nil = "no label, today's UX".
    /// Exhaustive switch, no default — a new outcome case must decide its UI
    /// consequence at compile time (L1 §10.3 totality).
    static func from(_ outcome: SystemContactPhotoWriteOutcome) -> FamilyPhotoEditorState?
}
```

| Outcome | State | Label keys |
|---|---|---|
| `.written` | `.updatedInSystem` | `family.photo.state.updatedInSystem` |
| `.skippedNoLink` | `nil` | none (today's behavior) |
| `.skippedNoAuthorization(.notDetermined)` | `.keptOnPhone` | `family.photo.state.keptOnPhone` |
| `.skippedNoAuthorization(.denied)` | `.keptOnPhoneAccessDenied` | `keptOnPhone` + `accessDeniedBody` |
| `.skippedNoAuthorization(.limited)` | `.keptOnPhone` | `family.photo.state.keptOnPhone` |
| `.failed(.notInGrantedSelection)` | `.keptOnPhone` | `family.photo.state.keptOnPhone` |
| `.recordGone` | `.keptOnPhone` | `family.photo.state.keptOnPhone` (+ stale-link line on next refresh) |
| `.identityMismatch` | `.keptOnPhone` | `family.photo.state.keptOnPhone` + wizard stale line |
| `.failed(.saveRejected)` | `.keptOnPhone` | `family.photo.state.keptOnPhone` |
| `.failed(.readBackMismatch)` | `.keptOnPhone` | `family.photo.state.keptOnPhone` (never false success) |
| remove-flow, clear succeeded but the record keeps its own photo | `.systemPhotoRemains` | `family.photo.state.systemPhotoRemains` |

Placement: the enum + mapping live in `SystemContactPhotoWriter.swift` next to the outcome
enum (totality is a seam property; tested in `SystemContactPhotoWriterTests`). The label KEYS
are resolved only in the view (`SettingsView.swift`), never in the seam.

### 1.6 Unified search — UnifiedContactSearch.swift changes

```swift
struct Outcome: Equatable {
    let entries: [Result]
    let moreAvailable: Bool
    /// Keyed by FAMILY result id ("family-<uuid>") → the linked phone-book record's
    /// display name, per L1 §7.1 Pass 3. Only synthesized rows appear here; the map
    /// is EMPTY for unlinked searches. Default [:] keeps existing constructions compiling.
    let linkedBookNames: [String: String]

    init(entries: [Result], moreAvailable: Bool, linkedBookNames: [String: String] = [:])
}

enum FamilyMatchTier: Int, Comparable {
    case exactName = 0
    case relationship = 1
    case nickname = 2        // NEW — any stored nickname: exact OR normalized substring
    case containment = 3     // renumbered (was 2); rawValue order IS quality order
}

static func search(query: String,
                   family: [FamilyContact],
                   index: FamilyContactIndex,
                   in entries: [AddressBookEntry],
                   verifiedLinks: VerifiedLinksSnapshot = .empty,
                   recency: [String: Date] = [:],
                   limit: Int = defaultLimit) -> Outcome

static func familyMatches(query: String,
                          in family: [FamilyContact],
                          index: FamilyContactIndex) -> [(contact: FamilyContact, tier: FamilyMatchTier)]

static func addressBookMatches(query: String, in entries: [AddressBookEntry]) -> [AddressBookEntry]  // unchanged

static func dedupe(matchedFamily: [FamilyContact],
                   in bookMatches: [AddressBookEntry]) -> [AddressBookEntry]   // unchanged (Pass 4)

static func rank(family: [(contact: FamilyContact, tier: FamilyMatchTier)],
                 book: [AddressBookEntry],
                 recency: [String: Date]) -> [Result]                          // unchanged
```

Algorithm (L1 §7.1 Passes 1-5, exact):
- Pass 1 `familyMatches`: tiers checked best-first. `.exactName` = index `normalizedName ==
  NepaliTextNormalizer.normalize(needle)`. `.relationship` unchanged. `.nickname` = the
  normalized query equals one of `entry.normalizedNicknames` (exact checked first via the O(1)
  map) OR the normalized query is a Character-safe substring of any normalized nickname —
  `range(of:options:[.caseInsensitive, .diacriticInsensitive])`, same direction as the name
  tier (nickname contains the query). Both land in tier `.nickname`; "exact > substring" is
  check ORDER only, with no ranking consequence by construction. `.containment` = today's name
  containment / digit rule, unchanged.
- Pass 2 `addressBookMatches` unchanged.
- Pass 3 link merge (new pure step): for each matched book row `b` whose `b.identifier` has
  `verifiedLinks.familyID(forIdentifier:)` = `f`:
  - `f ∈ matchedFamily` → DROP `b`.
  - else → SYNTHESIZE `(contact: f, tier: .containment)` and DROP `b`; set
    `linkedBookNames["family-\(f.id)"] = b.name`, suppressed when `NepaliTextNormalizer.normalize(b.name)
    == index.entry(for: f.id)?.normalizedName`.
- Pass 4 today's number `dedupe` over the REMAINING book rows (byte-for-byte today for
  unlinked pairs; every linked row is already gone).
- Pass 5 recount before the limit slice: `moreAvailable = familyCount + bookCount > limit`.

Single code path: the `index:` parameter is REQUIRED (no convenience overload that could
drift); all call sites (3 in LeafViews, the wizard, tests) pass an explicit index. Tests build
`FamilyContactIndex(family: family)` inline.

### 1.7 Voice resolution — ContactResolver.swift changes

```swift
init(contactsProvider: @escaping () -> [FamilyContact],
     indexProvider: (() -> FamilyContactIndex)? = nil)   // nil ⇒ build per call (test-parity path)
```

Scoring in `score(_:against:)` (bands per L1 §8.3; accept 0.6 and margin 0.15 remain the
private constants at :61-62; ties ⇒ ambiguity, never order):

| Band | Score | Source |
|---|---|---|
| exact name | 1.00 | index `normalizedName` |
| relationship | 0.90 | unchanged |
| exact nickname | 0.85 | index `normalizedNicknames` exact |
| name containment | 0.80 | unchanged |
| nickname containment | 0.75 | any normalized nickname contains the query (or query contains it — same both-direction shape as the name band) |
| token overlap | 0.60 | unchanged (name tokens) |

(Consequence-table note: the name-exact 1.00 vs nickname-exact 0.85 gap computes to
0.15000000000000002 in IEEE-754, so the strict `<` margin check resolves to the name-exact
contact — not ambiguous; pinned explicitly in §8.3.)

`nearMiss(_:)`: candidate set = contacts whose normalized name OR any normalized nickname is
within the edit budget (2) of a query variant; the existing exactly-one rule is preserved —
name-near-miss + nickname-near-miss in one query = two candidates = abstain. The hot path
consumes the index (no per-call renormalization of names/nicknames); relationship is
normalized per call exactly as today. Error type: none (pure); `.none` IS the honest failure.

### 1.8 Link-aware number reach — MissedCallContactResolver.swift changes

```swift
static func familyMatch(phone: String, in contacts: [FamilyContact]) -> FamilyContact?   // UNCHANGED

/// NEW: the family contact whose VERIFIED linked record carries this number —
/// roster order; each contact's own phone was already checked first by callers.
static func linkedFamilyMatch(phone: String,
                              in contacts: [FamilyContact],
                              snapshot: VerifiedLinksSnapshot) -> FamilyContact?

static func resolve(phone: String,
                    family: [FamilyContact],
                    native: [AddressBookEntry],
                    access: ContactsAccess,                       // now includes .limited
                    snapshot: VerifiedLinksSnapshot = .empty) -> NameResolution
```

`resolve` order (L1 §6.3, §7.3): (1) `familyMatch` on the family's own phones → family name;
(2) `linkedFamilyMatch` — a call from the linked record's number resolves to the FAMILY
person; (3) native half (gated on `access.allowsReading`): a matched entry whose
`identifier` is a verified link remaps to that family contact's name, else the book name;
(4) `.notDetermined` → `.needsPermission`; denial → `.unresolved`. Unverified/stale links are
absent from the snapshot, so they fall through to today's behavior exactly.

### 1.9 Coordinator API — AppCoordinator.swift additions

Published/derived state (all main-confined, L1 §13.1):

```swift
@Published private(set) var familyContacts: [FamilyContact] = [] {
    didSet {
        familyIndex = FamilyContactIndex(family: familyContacts)   // wholesale rebuild — drift-impossible
        refreshVerifiedLinks()                                     // no-op unless a stored link exists
    }
}
@Published private(set) var familyIndex: FamilyContactIndex = .empty
@Published private(set) var verifiedLinks: VerifiedLinksSnapshot = .empty
@Published private(set) var faceEpoch: UInt64 = 0        // identity/cache bump (§4.4)
private var systemPhotoTokens: [UUID: String] = [:]      // last-resolved system photo hash prefix
```

Faces (L1 §10.1):

```swift
/// ".task(id:)" identity: "<id>:<sysphoto-hash-token or link-nil>:<filename>:<faceEpoch>".
/// Token = sha256 prefix (16 hex chars) of the last-resolved system bytes for this
/// contact's verified link ("-" = linked, not yet resolved; "link-nil" = no verified link).
@MainActor func faceIdentity(for contact: FamilyContact) -> String

/// Precedence: (1) verified link + readable access + photoImageData → system image;
/// (2) app-local photoFilename; (3) nil (initials). System images are downsampled to
/// ContactPhotoStore.maxDimension before returning (memory bound). Never throws.
@MainActor func faceImage(for contact: FamilyContact) async -> UIImage?
@MainActor func faceThumbnail(for contact: FamilyContact, diameter: CGFloat,
                              displayScale: CGFloat) async -> UIImage?
```

`faceThumbnail` cache keys (L1 §10.1; the two sources can never collide):
`"sysphoto:<identifier>:<sha256-prefix(16)>"` via `DownsampledImageCache.shared.thumbnail(...)`,
or `"contact:<filename>"` via the existing `contactFace(...)` path. `faceIdentity` and both
face methods are `@MainActor` — the token map and published state are only ever touched on main.

Links:

```swift
enum SystemContactUnlinkMode: Equatable {
    case unlinkKeepingLocalAsIs                 // default: app-local file untouched
    case unlinkKeepingDisplayedPhotoLocally     // copy displayed system bytes app-local, then clear
    case unlinkAndClearAppLocalPhoto            // explicit "remove everything" choice
}

/// Pure mode rule the wizard applies before calling:
/// app-local file exists → .unlinkKeepingLocalAsIs; else displayed photo is the
/// system one → .unlinkKeepingDisplayedPhotoLocally; else → .unlinkKeepingLocalAsIs.
static func unlinkMode(appLocalFileExists: Bool, displayedPhotoIsSystem: Bool) -> SystemContactUnlinkMode

/// The ONLY unlink path (L1 §6.4). Clears the stored link, books the photo
/// consequence per `mode`, bumps the epoch, triggers a refresh. Never writes to
/// the system record. `true` = cleared (or already absent); `false` = no such contact
/// or the local copy failed (mode .unlinkKeepingDisplayedPhotoLocally without a
/// successful copy does NOT clear — the never-lose rule wins over the unlink).
@discardableResult @MainActor
func setFamilyContactLink(id: UUID, mode: SystemContactUnlinkMode) async -> Bool

/// The wizard's post-save system-photo step (L1 §10.2 step 2-3).
/// nil = the contact no longer exists; `.skippedNoLink` = no verified link;
/// `.skippedNoAuthorization(access)` = no attempt, honest fallback.
@MainActor
func syncSystemPhoto(forContactID id: UUID, clearing: Bool) async -> SystemContactPhotoWriteOutcome?

/// Refresh entry point: single-flight via the actor; early-returns (no fetch, no
/// generation bump) when NO roster contact carries a stored link. Never blocks main.
func refreshVerifiedLinks()
```

Add/update (L1 §11.1 signatures; `nickname:` is REPLACED — no shim):

```swift
@discardableResult
func addFamilyContact(id: UUID = UUID(),            // NEW defaulted id: the wizard knows the contact
                      name: String, phone: String, relationship: String,
                      messengerHandle: String? = nil,
                      photo: UIImage? = nil,
                      nicknames: [String] = [],
                      address: String? = nil, email: String? = nil,
                      isEmergencyContact: Bool = false,
                      link: SystemContactLink? = nil) -> Bool

@discardableResult
func updateFamilyContact(id: UUID, name: String, phone: String, relationship: String,
                         messengerHandle: String?,
                         photo: UIImage? = nil, removingPhoto: Bool = false,
                         nicknames: [String] = [],          // REQUIRED at the wizard call site (no default there)
                         address: String? = nil, email: String? = nil,
                         isEmergencyContact: Bool = false,
                         link: SystemContactLink? = nil) -> Bool
```

Semantics:
- `nicknames` normalized via `FamilyContact.normalizedNicknames` before persisting.
- `link` non-nil → set/replace; `link` nil on UPDATE → keep the stored link UNCHANGED (unlink
  is only `setFamilyContactLink`); nil on ADD → unlinked.
- Duplicate-claim guard (defense in depth, L1 §6.1): a non-nil `link.identifier` already
  claimed by ANOTHER contact's stored link → the write is REFUSED (return `false`, nothing
  persisted, reason-coded event `duplicate_claim`). The wizard's steering prevents this path.
- Return type stays `Bool`; callers at `SettingsView.swift:2761/2768`, `ProfileInterviewSteps.swift:530/562`,
  `OnboardingWizardView.swift:405` compile with the parameter changes only.
- After a successful persist: `familyContacts` republish (→ index rebuild + link refresh).
- Unchanged: photo save-first/delete-on-failure sequencing; `removeFamilyContact` unchanged
  except it rides the same republish choke point (a removed contact's link simply leaves the roster).

`contactPhotoStore` gains one reader used by `syncSystemPhoto` and nothing else:

```swift
/// Raw bytes of a stored thumbnail (the exact processed JPEG on disk), nil when
/// absent/unsafe. Avoids a decode+re-encode round trip for the system write —
/// the bytes written are byte-identical to the bytes the app holds.
func loadData(named filename: String?) -> Data?
```

## 2. Wizard sheet restructure (`FamilyContactWizardSheet`, SettingsView.swift:1779ff)

Steps stay five; the indicator is untouched. `Step` enum unchanged.

### 2.1 Draft state (final)

Removed: `@State private var nickname = ""`.
Added/changed:

```swift
@State private var nicknames: [String] = []          // committed entries (draft)
@State private var nicknameDraft = ""                // the add-field text

@State private var draftLink: SystemContactLink?     // picked-but-uncommitted link
@State private var draftLinkBookName: String?        // the picked record's display name at pick time
@State private var steerTarget: FamilyContact?       // the other contact shown in a steering card
@State private var photoSaveState: FamilyPhotoEditorState?   // post-save outcome label (§1.5)
```

Unchanged: `name/phone/relationshipOption/messengerHandle/address/email/isEmergencyContact`,
the photo trio (`pickedPhoto/removingStoredPhoto/storedPhoto`), the search block
(`searchText/access/entries/loadFailed/showManualEntry`), `directory`.

`init` gains the steering callback:

```swift
init(target: FamilyContactsSettingsView.FamilyContactEditorTarget,
     onSteerTo: @escaping (FamilyContact) -> Void)
```

parent call site :1587 becomes `FamilyContactWizardSheet(target: target) { other in editorTarget = .edit(other) }`.

### 2.2 Find step — subview breakdown

`findStep` = `stepTitle("family.step.find")` + `searchSection` + `linkSection` +
(`showManualEntry ? manualEntryFields : addManuallyButton`). The link area renders INSIDE the
find step (L1 §11.1) and is present in add AND edit.

- `searchSection` (:2114-2139; a `switch` over `ContactsAccess?` — the new case breaks the
  build, so this site IS compile-forced): `.allowed` and `.limited` share one arm (field +
  loading/loadFailed card + results); for `.limited` the `call.search.accessLimited` caption
  renders directly under `searchField` (one line, caption token, secondary color). `.denied` /
  `.notDetermined` / `nil` arms unchanged — `.denied` is the ONLY blocked path on both
  surfaces. The load gate `refreshSearchAccess` (:2325) moves to `status.allowsReading`
  (entries load for `.limited`; §3.5, §8.2).
- `searchResults` — NOW `UnifiedContactSearch.search(query: trimmedSearch,
  family: coordinator.familyContacts, index: coordinator.familyIndex, in: entries,
  verifiedLinks: coordinator.verifiedLinks, recency: coordinator.contactCallRecency)` —
  renders per row kind:
  - `.addressBook(entry)`: if `storedClaimant(entry.identifier)` is a DIFFERENT roster
    contact (stored link, verified or stale — the superset) → `steeringResultRow(claimant)`;
    else today's selectable row (tap = `prefill`), which additionally records the draft link.
  - `.family(contact)`: `steeringResultRow(contact)`, EXCEPT when `contact.id ==
    editingContact?.id` — skipped entirely (it is the contact already being edited; its own
    link is shown in the link area).
  - `noResults` / `moreAvailable` unchanged.
- `steeringResultRow(_ other: FamilyContact)`: a card containing
  `Text(L10n.fmt("family.link.alreadyLinked", locale: coordinator.activeLocale, other.name))`
  and a ≥44 pt button (person
  glyph + `other.name`, a11y label `settings.family.edit`) whose tap calls
  `onSteerTo(other)`. Tap target: whole card ≥44 pt (`DesignTokens.minTapTargetSize` floor);
  the button itself also ≥44 pt.
- `prefill(_ entry: AddressBookEntry)` gains the link record (L1 §11.1 "selects it as today
  AND records the link in the draft"):

```swift
private func prefill(_ entry: AddressBookEntry) {
    name = entry.name
    phone = entry.phone
    showManualEntry = true
    searchText = ""
    guard !entry.identifier.isEmpty else { return }        // defensive canLink guard (L1 §5.3)
    draftLink = SystemContactLink(identifier: entry.identifier, numberKey: entry.normalized)
    draftLinkBookName = entry.name
}
```

- `storedClaimant(_ identifier: String) -> FamilyContact?` (private): first roster contact
  `c != editingContact` with `c.systemContact?.identifier == identifier` (roster order).
- `linkSection` states (top of the find step, under the search):
  1. `draftLink != nil` → `linkedToLine(draftLinkBookName ?? "-")` + `unlinkButton` (clears
     `draftLink`/`draftLinkBookName` only — nothing was stored).
  2. else an EDITING contact with a stored link, verified (`coordinator.verifiedLinks.links[contact.id]`
     present) → `linkedToLine(resolvedBookName)` + `unlinkButton` (commits immediately via
     `setFamilyContactLink`, §2.6).
  3. else an EDITING contact with a stale (stored, unverified) link → `staleLine`
     (`family.link.stale`) + `unlinkButton`.
  4. else → `Text("family.link.pickHint")` caption only (with `family.link.sectionTitle`
     heading at the top of the section in all four states).
- `resolvedBookName` = `entries?.first { $0.identifier == link.identifier }?.name`; when the
  record is not in the sweep while the snapshot still verifies it (narrow window), the
  linkedTo line renders without a name — the stale line is the snapshot's decision, not the
  sweep's. `family.link.linkedTo` is rendered with `L10n.fmt`.
- a11y for `unlinkButton`: label `family.link.unlink`, hint `family.link.unlinkHint` (the
  hint text is also visible as a caption under the button).

### 2.3 Steering micro-flow (final, L1 §19 item)

1. Tap on an already-linked result (or a synthesized family row) → `steerTarget = other`;
   nothing is selected, no field changes, no store write.
2. The steering card renders inline under the results (a `family.link.alreadyLinked` text +
   the edit button). Tap targets ≥44 pt; VoiceOver reads the sentence, then the button.
3. Tapping the edit button calls `onSteerTo(other)`; the PARENT sets `editorTarget = .edit(other)`
   and `.sheet(item:)` swaps the sheet's content to the other contact's editor in place (the
   item id changes → SwiftUI replaces the content; the old draft is discarded, which is
   correct — nothing was saved). No dismiss/re-present race.
4. Back-navigation INTO the other contact's editor: the swapped sheet opens at its
   `.relationship` step (the edit rule); its Back reaches ITS find step; closing returns to
   the family list. There is no in-sheet stack back to the first contact (documented; the
   first contact's draft was never committed and re-opening it is one row away).
5. `steerTarget` is cleared by any new search keystroke or a successful pick.

### 2.4 Photo step — subview breakdown

`photoStep` = `stepTitle("family.step.photo")` + `photoPreview` + `sourceCaption` +
`photoControls` + `writeAccessCards` + `photoStateLine`.

- `sourceCaption`: renders `family.photo.sourceSystem` when the displayed photo is the
  resolved SYSTEM one (verified link + readable access + bytes present). Derived, not stored.
- `writeAccessCards` (linked + editing only):
  - access `.notDetermined` → `askCard(title: family.photo.accessTitle, body: family.photo.accessBody,
    allow: call.search.allowButton)` reusing the wizard's existing ask-card pattern; Allow
    calls the existing `grantAccess()`; declining (just not tapping) continues with fallback.
  - access `.denied` → `deniedLine(family.photo.accessDeniedBody)` + Open Settings
    (`call.search.openSettings`, existing system-settings link pattern).
  - access `.limited` → NO card (readable; honest caption already lives in the find step).
- `photoStateLine`: renders `photoSaveState` (§1.5 mapping) under the preview — caption token,
  secondary color, plus `family.photo.accessDeniedBody` when the state is
  `.keptOnPhoneAccessDenied`.
- `photoControls` unchanged (`family.photo.add/change`, `family.photo.remove` for stored photos).

### 2.5 Nickname step — subview breakdown

`nicknameStep` = `stepTitle("family.step.nickname")` + `nicknameList` + `nicknameAddRow` +
`nicknameHint` + the unchanged address/email fields below.

For each entry (`ForEach(Array(nicknames.enumerated()), id: \.offset)` — one row per
OCCURRENCE; duplicates are preserved per §3.4):

```
HStack(spacing: 12) {
    Text(entry)                                   // the stored spelling verbatim
        .font(bodyPointSize), textPrimary, lineLimit(2)
    Spacer()
    Button(remove) { nicknames.remove(at: index) }
        .frame(minWidth: minTapTargetSize, minHeight: minTapTargetSize)   // ≥44pt
        .accessibilityLabel(Text(L10n.fmt("family.nickname.removeLabel", locale, entry)))
}
.frame(minHeight: minTapTargetSize).appSurface(role: .control, cornerRadius: bubbleCornerRadius)
```

`nicknameAddRow` (hidden at 8 entries — the L1 §8.4 budget envelope; nothing is ever dropped,
the control simply stops offering more):

```
TextField("", text: $nicknameDraft, prompt: family.nickname.entryPlaceholder)   // placeholder key
Button(family.nickname.add) {
    let trimmed = nicknameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }        // whitespace-only never stored (FR-FCU-011)
    nicknames.append(trimmed)                     // stored AS ENTERED — no transliteration (OD-2)
    nicknameDraft = ""
}
.frame(minHeight: minTapTargetSize)               // Add button ≥44pt; accessibilityLabel family.nickname.add
```

`nicknameHint` = `family.nickname.hint` caption. Validation summary: trim at the Add control;
whitespace-only rejected at entry; `normalizedNicknames` re-applies the rule at save and at
decode (defense in depth). Duplicates allowed by design (decode preserves them; the editor is a
faithful editor of the stored list); "sanu" and "सानु" are always distinct entries.
Removal is a save-time edit like every other field; saved changes take effect immediately
after Save (index rebuild on the roster republish — FR-FCU-015).

`loadDraft()`: `nicknames = contact.nicknames` (replaces `nickname = contact.nickname ?? ""`).

### 2.6 Save flow (final, L1 §10.2 sequencing)

```swift
private func save() {
    let savedID = editingContact?.id ?? newDraftID      // @State let for the add case (see below)
    let succeeded: Bool
    if let contact = editingContact {
        succeeded = coordinator.updateFamilyContact(id: contact.id, ..., nicknames: nicknames, link: draftLink)
    } else {
        succeeded = coordinator.addFamilyContact(id: savedID, ..., nicknames: nicknames, link: draftLink)
    }
    guard succeeded else { return }                     // failure keeps the draft (today)
    let photoIntent = pickedPhoto != nil || removingStoredPhoto
    guard photoIntent else { dismiss(); return }        // no photo changed → today's UX
    Task { @MainActor in
        let outcome = await coordinator.syncSystemPhoto(forContactID: savedID, clearing: removingStoredPhoto)
        if let state = outcome.flatMap(FamilyPhotoEditorState.from) {
            photoSaveState = state
            step = .photo                              // show the honest label where it lives
        } else {
            dismiss()                                  // .written or .skippedNoLink → today's UX
        }
    }
}
```

- `newDraftID`: `@State private var newDraftID = UUID()` created in `init` for the add case
  (stable across re-saves) — the wizard knows the contact's id before the store write.
- Footer: when `photoSaveState != nil` the primary button becomes `common.close` (dismiss) —
  the sheet stays open exactly so the owner sees what happened (L1 §10.2 step 3).
- The unlink control in the link area calls, in a Task,
  `coordinator.setFamilyContactLink(id:mode:)` with the mode from `unlinkMode(...)` using the
  CURRENT state (verified snapshot + `photoFilename`); on `false` nothing changes (draft kept,
  the stale line stays).
- `.systemPhotoRemains` is set in the REMOVE path (removingPhoto + linked): the clear attempt
  returns `.written`; the wizard then checks the display precedence — a system photo still
  present (its bytes were not ours / access lost between attempts) maps to the label via the
  `systemPhotoRemains` row of §1.5. Any other outcome maps through the same table.

### 2.7 Family list (SettingsView, `FamilyContactsSettingsView`)

- Row gains the link chip: `family.link.chip` capsule appended to the role-chip row when
  `coordinator.verifiedLinks.links[contact.id] != nil` (verified links only; a stale link
  shows nothing here — the editor owns that line).
- Row faces migrate: `.task(id: contactPhotoKey)` where `contactPhotoKey` becomes the array of
  `coordinator.faceIdentity(for:)` for every roster contact (identity includes filename, link
  token and epoch). The pass resolves each face via
  `await coordinator.faceThumbnail(for: diameter: DesignTokens.iconBadgeDiameter, displayScale:)`
  and assigns per-row only after re-checking the identity is unchanged (stale-pass drop).
- `loadDraft`'s stored-photo preview: `storedPhoto = await coordinator.faceImage(for: contact)`
  (the editor shows the DISPLAY photo — system when present, with the source caption).

## 3. Data model and persistence contract

### 3.1 Final `FamilyContact` (FamilyContactStore.swift:61)

```swift
struct FamilyContact: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var phone: String
    var relationship: String
    var messengerHandle: String?
    var photoFilename: String?
    var nicknames: [String]              // REPLACES nickname: String? (no shim — L1 §5.2)
    var address: String?
    var email: String?
    var isEmergencyContact: Bool
    var preferredVideoApp: CallApp
    var preferredCallApp: CallApp
    var systemContact: SystemContactLink?   // NEW

    init(id: UUID = UUID(), name: String, phone: String, relationship: String,
         messengerHandle: String? = nil,
         preferredVideoApp: CallApp = .faceTime, preferredCallApp: CallApp = .phone,
         photoFilename: String? = nil, nicknames: [String] = [],
         address: String? = nil, email: String? = nil,
         isEmergencyContact: Bool = false, systemContact: SystemContactLink? = nil)
}
```

### 3.2 `normalizedNicknames` — exact placement and semantics (L1 §19 item)

`static func normalizedNicknames(_ raw: [String]) -> [String]` on `FamilyContact` in
`FamilyContactStore.swift` (same file as the decode contract it serves): trim each entry with
`.whitespacesAndNewlines`, drop entries that become empty, preserve order and duplicates.
Applied at exactly three places: the decoder (defensive for hand-edited/corrupt payloads), the
wizard's Add control (single-entry trim), and the coordinator's add/update save path (the
enforcement point every caller passes through). The store never sees a whitespace-only entry.

### 3.3 Encoder contract

Synthesized `Encodable` is kept (L1 §5.2 — a hand-written encoder risks silent field loss).
Nil optionals are omitted (`encodeIfPresent`); `nicknames`/`systemContact` are always encoded
as stored (`[]` keeps encoding an empty array — same shape as any empty array today). No
legacy `nickname` key is ever written (downgrade reads simply show no nickname — accepted).

### 3.4 Decoder contract (FamilyContactStore.swift:122-150 pattern)

```swift
private enum LegacyNicknameKeys: String, CodingKey { case nickname }

init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // ... existing required fields and optionals unchanged ...
    preferredVideoApp = (try? container.decode(CallApp.self, forKey: .preferredVideoApp)) ?? .faceTime
    preferredCallApp  = (try? container.decode(CallApp.self, forKey: .preferredCallApp)) ?? .phone
    photoFilename     = (try? container.decodeIfPresent(String.self, forKey: .photoFilename)) ?? nil

    // nicknames — L1 §5.2 order, lossless:
    if let list = (try? container.decodeIfPresent([String].self, forKey: .nicknames)) ?? nil {
        nicknames = FamilyContact.normalizedNicknames(list)          // presence wins, even empty
    } else if let legacy = try? decoder.container(keyedBy: LegacyNicknameKeys.self),
              let single = (try? legacy.decodeIfPresent(String.self, forKey: .nickname)) ?? nil,
              !single.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        nicknames = [single.trimmingCharacters(in: .whitespacesAndNewlines)]
    } else {
        nicknames = []
    }

    // systemContact — corrupt/empty shapes decode to nil (FR-FCU-002 scenario 3):
    let decodedLink = (try? container.decodeIfPresent(SystemContactLink.self, forKey: .systemContact)) ?? nil
    if let link = decodedLink, !link.identifier.isEmpty, !link.numberKey.isEmpty {
        systemContact = link
    } else {
        systemContact = nil
    }
    // ... address/email/isEmergencyContact unchanged ...
}
```

`CodingKeys` contains ONLY stored properties (`nicknames`, `systemContact` included); the
legacy key is read through the separate `LegacyNicknameKeys` container so the synthesized
`CodingKeys`/encoder stay authoritative. `(try? ...) ?? nil` covers absent key, wrong type and
unknown shape — decode-degrade, never a failed store read.

### 3.5 AddressBookEntry.identifier (AddressBookDirectory.swift)

`var identifier: String = ""` added to the stored properties (`Equatable`/`Identifiable`
unchanged); `make(...)` gains `identifier: String = ""` so every existing labeled call site
(test fixtures included) compiles unchanged; `fetchKeys` (:333) adds `CNContactIdentifierKey`;
`allEntries()` passes `contact.identifier` through. Linking is available only for non-empty
identifiers (the `prefill` guard — §2.2). No persistence of book entries exists, so no
migration applies. `ContactsAccess` gains the case + helper (same file):

```swift
enum ContactsAccess: Equatable {
    case notDetermined, allowed, denied
    case limited                                    // iOS 18+ "Select Contacts"

    /// `.allowed` and `.limited` are READABLE; denial/nagging logic keys on
    /// `.denied` only — limited never re-prompts (L1 §9.3).
    var allowsReading: Bool { self == .allowed || self == .limited }

    /// Pure mapping — the ONE iOS-18 availability gate in the feature.
    static func from(_ status: CNAuthorizationStatus) -> ContactsAccess {
        if #available(iOS 18.0, *), status == .limited { return .limited }
        switch status {
        case .authorized: return .allowed
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied          // future statuses fail closed
        }
    }
}
// AddressBookDirectory.access() :348 becomes: ContactsAccess.from(CNContactStore.authorizationStatus(for: .contacts))
```

`.limited` reaches consumers through `AddressBookDirectory.access()`. Handling is NOT
uniformly compile-forced — equality checks compile cleanly with the new case and silently
take the else path — so every site is enumerated and decided here (each listed line is a
required change):

- **Compile-forced switches**: `MissedCallContactResolver.resolve` (its `access:` switch) and
  the wizard's `searchSection` (`SettingsView.swift:2117`, a switch over `ContactsAccess?`)
  fail the build until `.limited` is handled. Resolver: `.limited` is readable (§1.8).
  Wizard: `.allowed`/`.limited` share the search body; `.limited` adds the caption (§2.2).
- **CallView (`LeafViews.swift`) — equality checks, NOT compile-forced; `.limited` takes
  today's `.allowed` display path (field + entries + mic) and `.denied` stays the only
  blocked path; every site below moves to `allowsReading`** (`access` is `ContactsAccess?`
  there, hence the optional form):
  - :1343 `if access == .allowed { searchField }` → `if access?.allowsReading == true`.
  - :1347-1362 display branches → `if access?.allowsReading == true { <micCaption; loading /
    loadFailed card / results> } else if access == .denied { blocked card } else if
    access == .notDetermined { ask card }` (`nil` renders nothing, as today). `.limited` can
    never render the empty dead area.
  - :1370 `refreshDirectory` → `guard status.allowsReading else { return }`; `loadEntries()`
    runs for `.limited` (the granted set loads).
  - :1379-1388 `grantAccess` load condition `if granted` → `if access?.allowsReading == true`
    (the system sheet may yield `.limited`).
  - :1413 `micButtonVisible` → `guard !micHidden, access?.allowsReading == true`.
  - :1519 `announceVoiceResultIfReady` → `access?.allowsReading == true`.
- **Caption placement (decided)**: `call.search.accessLimited` renders on BOTH search
  surfaces — CallView: the FIRST line of the readable block inside `searchArea`, directly
  under the field row and above `micCaption` (caption token, secondary color, one line);
  wizard: directly under `searchField` in the shared `.allowed`/`.limited` arm (§2.2). This
  satisfies L1 §9.3's honesty requirement at the point of use on both surfaces.
- **Wizard load gate + grant**: `refreshSearchAccess` (:2322-2329; called from `.onAppear`
  :1977 and `scenePhase` :1983) → `guard status.allowsReading`; `loadEntries()` runs for
  `.limited`. `grantAccess` (:2331-2339) load condition `if granted` →
  `if access?.allowsReading == true`. Without these, relaunching with already-granted limited
  access renders the §2.2 search UI over an unloaded book.
- **AppCoordinator — `refreshNativeMissedCallNames` (:8327-8358), the FIFTH
  `AddressBookDirectory.access()` consumer** (runs on a detached utility Task with a LOCAL
  access snapshot — nothing in this call touches published state): after `requestAccess()`
  (:8335) RE-READ the status — replace `access = granted ? .allowed : .denied` (:8336) with
  `_ = await directory.requestAccess()` + `access = AddressBookDirectory.access()` (a
  limited-selection sheet must not be collapsed to `.allowed`) — change the guard (:8338) to
  `guard access.allowsReading, let entries = try? directory.allEntries()` (the granted set
  enumerates under `.limited`), and pass the REAL value at :8346 (`access: access`) instead
  of the hardcoded `access: .allowed` — the resolver's own `.limited`-readable arm then
  makes the decision.
- **Pins that can fail**: `ContactsAccessTests` (new) pins the pure mapping
  (`.limited` ⇒ `.allowsReading`; `.denied`/`.notDetermined` ⇒ false; the `from(_:)` table);
  `ContactsAccessGateTests` (new, source-scan) extracts each enumerated expression/function
  body above and asserts `allowsReading` is present and a `== .allowed` gate is ABSENT — a
  reverted gate fails the suite. (§6.4, §8.3, §9 R2.)

### 3.6 Snapshot / index lifecycle

- **Index**: rebuilt wholesale inside `familyContacts.didSet` (one choke point — boot restore,
  add, update, remove, notifier paths all assign through it). `FamilyContactIndex` never
  disagrees with the published roster by construction (L1 §5.4).
- **Snapshot**: `verifiedLinks` starts `.empty`; `refreshVerifiedLinks()` early-returns unless
  some contact carries a stored link (so an unlinked roster NEVER fetches) and otherwise
  spawns one Task that captures the roster by value, awaits the actor, and publishes on main:
  publish iff `snapshot.generation > verifiedLinks.generation`; bump `faceEpoch` when
  `snapshot.links != verifiedLinks.links` (verification-set change). Stale snapshots
  (lower generation) are dropped — the counter orders PUBLICATION only; input freshness is
  guaranteed by the §4.2 drain loop, not by the generation guard. `.empty` ⇒ today's behavior
  exactly.

## 4. Concurrency specification (explicit)

### 4.1 Isolation matrix (extends L1 §13.1)

| Component | Isolation | Readers | Writers | Mechanism |
|---|---|---|---|---|
| `familyContacts`, `familyIndex`, `verifiedLinks`, `faceEpoch`, `systemPhotoTokens` | main thread | views, coordinator methods | the coordinator (main-queue blocks) | ObservableObject main confinement; `@MainActor` on the new async face/link methods |
| `FamilyContactIndex`, `UnifiedContactSearch`, resolvers, normalizer | pure values | any thread | construction only | no shared mutable state |
| `SystemContactLinkService` (+ its photo cache) | actor | concurrent `await`s | the actor alone | actor isolation; `NSCache` internal to the actor |
| `SystemContactPhotoWriter` | actor | — | the actor alone | actor isolation ⇒ writes strictly serial |
| `DownsampledImageCache` | existing `NSCache` | any thread | any thread | NSCache thread safety (unchanged) |

### 4.2 Single-flight verification — latest-roster capture, coalesced drain

Inside `SystemContactLinkService`:

```swift
private var refreshInFlight = false
private var pendingContacts: [FamilyContact]? = nil   // the LATEST coalesced roster request
private var lastSnapshot: VerifiedLinksSnapshot = .empty
private var generation: UInt64 = 0
```

`refresh(contacts:)` (actor-serialized):

- **Fast path** (`refreshInFlight == false`): set in-flight, then drain:

```swift
var next: [FamilyContact]? = contacts
while let batch = next {
    next = nil
    // ONE batched fetch over `batch`; on success: generation += 1; lastSnapshot = snapshot.
    // Fetch throw / unreadable access: lastSnapshot unchanged (degraded, reason-coded).
    next = pendingContacts    // a trigger that arrived during THIS pass is consumed here
    pendingContacts = nil
}
refreshInFlight = false
return lastSnapshot
```

- **Coalesced path** (`refreshInFlight == true`): `pendingContacts = contacts` — OVERWRITE
  with the LATEST roster (never merged, never the first one seen) — then return `lastSnapshot`.

Flag lifecycle when a dirty-set lands DURING the follow-up pass: `refreshInFlight` stays true
for the whole drain, so every trigger arriving during ANY pass (first or follow-up) takes the
coalesced path and overwrites `pendingContacts`; the loop's consume converts it into exactly
one more pass running with THAT latest roster. The loop exits only after a pass completes with
`pendingContacts == nil`, and the in-flight flag clears only then — so a trigger arriving
after the flag clears takes the fast path instead (actor serialization makes the two cases —
captured vs. fresh start — mutually exclusive; no trigger is lost in either ordering).

What the mechanism actually guarantees (this replaces the earlier "latest wins" phrasing):

- **No trigger is dropped**: every accepted call either runs a pass itself or leaves a pending
  roster the drain consumes — a just-created link submitted during an in-flight refresh is
  verified by the follow-up pass, NOT deferred to the next external trigger.
- **Each pass runs with the latest roster captured before that pass started** — the follow-up
  consumes `pendingContacts`, never the in-flight call's older roster.
- **At quiescence** (no pass running, no pending roster) the published snapshot was computed
  over the most recent roster submitted to `refresh(contacts:)`; a submission landing after
  quiescence starts a new pass and becomes the new latest (convergence one pass later in the
  worst case). Each completed pass updates `lastSnapshot`/`generation`; the drained result is
  carried back by the fast-path caller, while coalesced callers' early `lastSnapshot` returns
  are dropped by the coordinator's generation guard.
- **Bounded work / coalescing**: ANY number of triggers arriving during one pass cost exactly
  ONE additional pass (not N); the drain terminates when a pass completes with no pending
  roster — each extension needs a new external trigger. The `generation` counter orders
  PUBLICATION (the coordinator drops a snapshot whose generation ≤ the published one); it
  detects stale snapshots, NOT stale inputs — input freshness is provided solely by the
  `pendingContacts` capture above.
- Testable via the fake reader (`SystemContactLinkServiceTests`, §8.3): trigger-during-pass
  runs one follow-up with the new roster; N triggers during one pass cost one extra pass; a
  trigger after the flag clears runs a fresh pass; coalesced returns are droppable by the
  generation guard.

### 4.3 Photo cache constants (L1 §19 item — final)

```swift
// SystemContactLinkService, both named (no literals anywhere):
static let photoCacheCountLimit = 24          // ≈ 12 linked contacts × 2 sweep generations
static let photoCacheTotalCostLimit = 16 * 1024 * 1024    // 16 MiB of raw photo bytes
static let photoKeyHashPrefixLength = 16      // hex chars of the sha256 cache-key prefix
```

`cost` = `data.count` (raw bytes). Eviction: NSCache default (cost-bounded + memory pressure).
Invalidation: WHOLESALE (`invalidate(identifier: nil)`) on foreground (after which the app
cannot know whether the user edited a photo in Contacts.app) and PER-IDENTIFIER after our own
successful `writePhoto`/`clearPhoto`. Reads are cache-aside; a miss costs one CNContact fetch
(≤12 linked contacts, never a loop).

### 4.4 Face resolution — identity-keyed tasks, stale-completion dropping, refresh epochs

- `faceIdentity(for:)` = `"<id.uuidString>:<token>:<photoFilename ?? "-">:<faceEpoch>"`, where
  `token` = `systemPhotoTokens[contact.id]` (sha256 prefix of the last-resolved system bytes)
  or `"-"` (linked, not yet resolved) or `"link-nil"` (no verified link). `systemPhotoTokens`
  is written ONLY inside the `@MainActor` face methods.
- Convergence: a foreground epoch bump re-runs `.task(id:)`; the resolve observes new system
  bytes, updates the token, and the identity changes once more → exactly one extra resolve
  that now hits the photo cache (bytes unchanged ⇒ same hash ⇒ identity stable). Bounded; no
  loop.
- Call sites: `ContactTile.task(id: coordinator.faceIdentity(for: contact))`;
  the Settings list and CallView batch passes key on the ARRAY of identities. Every task body
  re-checks `coordinator.faceIdentity(for:)` after its `await` and abandons the assignment on
  a mismatch (`.task` cancellation is best-effort; the guard is the guarantee).
- `faceEpoch` bumps (main): `setFamilyContactLink` success; add/update where `systemContact`
  changed; `verifiedLinks.links` change on publish; every successful `writePhoto`/`clearPhoto`
  (paired with `invalidate(identifier:)`); every foreground activation (after wholesale cache
  invalidation — the only way an EXTERNAL photo edit surfaces). Cost: ≤12 re-resolves per
  foreground, each a cache hit or one bounded fetch.

### 4.5 Refresh-epoch ordering — launch/foreground hooks (L1 §19 item)

- **Launch**: inside `bootRestoreData`'s main block (`AppCoordinator.swift:3955-3986`), the
  `self.familyContacts = batch.contacts` assignment already fires `didSet` → index rebuild +
  `refreshVerifiedLinks()`. This lands AFTER the roster publish and BEFORE
  `startupBoot.advance(to: .preparingVoice)` (the Task spawn is non-blocking; the boot
  signpost interval semantics are untouched).
- **Foreground**: in `handleScenePhase(.active)` (`:9967`), after the existing hooks append
  exactly one call:

```swift
refreshContactsIdentity()   // (1) await-free: spawns Task { await linkService.invalidate(identifier: nil);
                            //     faceEpoch += 1 }; then (2) refreshVerifiedLinks()
```

  Order inside: (1) invalidation + epoch bump, (2) refresh — the refresh's photo reads (if
  any) then see fresh bytes. Both non-blocking; `.background` is untouched.
- **Roster mutation**: covered by the `didSet` choke point (add/update/remove/boot all assign).
- **Access change**: the wizard's `grantAccess()` and CallView's grant path call
  `refreshVerifiedLinks()` after a successful `requestAccess()` (a newly readable book can
  verify links); returning from iOS Settings is already covered by the `.active` hook.
- **After write outcomes**: `.written` → `invalidate(identifier:)` + `faceEpoch += 1`;
  `.recordGone`/`.identityMismatch` → `refreshVerifiedLinks()` (the link may now degrade —
  §1.5). No other outcome triggers anything.
- **No retries, no backoff, no delays, no timeouts** (L1 §13.4). A failed refresh leaves the
  previous snapshot; the next trigger (mutation/foreground/access/write) re-runs it. If a
  wait ever became necessary it MUST be a named configurable constant on the existing
  configuration surface — never a literal. None exists today.

## 5. Error handling and observability

### 5.1 Total outcome→UI mapping

See §1.5 — the table is the complete mapping; `FamilyPhotoEditorState.from` is an exhaustive
switch (adding a case breaks the build, forcing a UI decision). Byte-level guarantee relied
on by the fallback copy: the app-local processed JPEG is persisted in the SAME store write as
the contact, BEFORE any system attempt (L1 §10.2 step 1), so "kept in this app only" is true
even for `.failed(.readBackMismatch)`, where the system bytes may in fact have landed.

### 5.2 Logging rules per file (NFR-FCU-002)

- New feature-role files (`SystemContactLinkService.swift`, `SystemContactPhotoWriter.swift`,
  `FamilyContactIndex.swift`): NO console writes at all — any configuration, any build (the
  gate's rule 3). All diagnostics go through an injected `ObservabilityBus`
  (`Services/MedicationScheduler/DependencyProtocols.swift:23`) with the closed vocabularies
  below and only allow-listed metadata keys (`outcome`, `state`, `error_code`, `duration_ms`,
  `entry_count`, `contact_id_hash` — verified in `LogSanitiser.allowedKeys`).
- Existing touched files (AppCoordinator, SettingsView, LeafViews, AddressBookDirectory,
  MissedCallContactResolver, ContactResolver, ContactPhotoStore, ViewCaches): no new console
  writes; any future line must stay reason-code-only (no names, numbers, identifiers,
  nicknames, filenames, image bytes, no content-bearing event fields).
- Events (classification-only; `contact_id_hash` unused — no id is needed to diagnose):

| component | eventType | outcome (closed) | errorCode | metadata |
|---|---|---|---|---|
| `contacts_link` | `refresh_completed` | `ok` \| `degraded` | nil \| `fetch_failed` | `{"entry_count": "<verified count>"}` |
| `contacts_link` | `unlink` | `keeping_local_as_is` \| `keeping_displayed_photo_locally` \| `clear_app_local_photo` | nil | none |
| `contacts_link` | `claim_refused` | `refused` | `duplicate_claim` | none |
| `contacts_photo` | `write` | outcome `logToken`: `written` \| `skipped_no_link` \| `skipped_no_authorization` \| `record_gone` \| `identity_mismatch` \| `failed` | failure raw value when `.failed`, else nil | `{"state": <not_determined\|denied\|limited\|full>}` for `skipped_no_authorization`; none otherwise |

`duration_ms` set on `refresh_completed` and `write`. `PhotoWriteIntent.imageBytesHash` (test
fake + DEBUG assertion) is a hash by construction. No name/number/nickname byte content ever
enters an event field.

### 5.3 Release-gate wiring

`ios/tools/check-release-log-safety.py` `FEATURE_ROOTS` (source-root-relative) gains:

```py
    # [FAMILY-CONTACTS-UNIFY design-l2 §5.2] Link/nickname identity + the write seam:
    # names, nicknames, phone numbers, identifiers and photo bytes are household data.
    # A Release console write or an unlisted metadata key anywhere in these files
    # fails the gate; events route through ObservabilityBus with allow-listed keys only.
    "Services/Contacts/SystemContactLinkService.swift",
    "Services/Contacts/SystemContactPhotoWriter.swift",
    "Services/Contacts/FamilyContactIndex.swift",
```

The fixture harness keeps passing unchanged (positive/negative fixture per rule); the gate
stays wired into `ios/build.sh` ahead of every test scope. Existing coordinator/UI paths stay
outside the feature role (they carry pre-existing console writes), but their new lines follow
the reason-code rule and the transcript rules (gate rules 1-2 walk the whole tree already).

## 6. Performance and security implementation patterns

### 6.1 ≤20 ms budgets (NFR-FCU-001)

- **Build** (once per roster publish): 12 contacts × (1 name + ≤8 nicknames) = ≤108
  `NepaliTextNormalizer.normalize` calls + ≤108 map insertions — measured sub-millisecond;
  asserted by `FamilyContactIndexTests` (max-roster build ≤20 ms ceiling).
- **Search per keystroke**: normalize the query ONCE; `.exactName` compares against
  `entry.normalizedName` (no per-call normalization); `.nickname` exact via one
  `idsByNickname[normalizedQuery]` O(1) hit; `.nickname` substring = ≤9 `range(of:)` checks
  per contact over PREcomputed normalized strings (bounded 12×9 = ≤108 range checks);
  `.containment` today's raw checks. Strictly cheaper than today's per-call name
  normalization. Measured assertion ceiling in `UnifiedContactSearchTests`.
- **Voice per utterance**: one query normalization + variants; per contact: 1 index lookup +
  ≤9 normalized comparisons (exact nickname) + ≤9 containment checks + relationship + token
  logic; near-miss walks name + ≤8 nicknames with the early-exit edit distance. Bounded
  12×(1+9+9) small-string ops; measured ceiling in `ContactResolverTests`.
- The 8-per-contact editor cap (§2.5) keeps production inside the tested envelope; the MODEL
  and decoder accept more without failing (budgets degrade gracefully, nothing truncates).
- Measured values are logged into the test output and recorded at DV; no production timers.

### 6.2 CNSaveRequest confinement — three enforcement layers

1. **File-local construction**: `CNSaveRequest` and `CNMutableContact` are constructed ONLY in
   `Services/Contacts/SystemContactPhotoWriter.swift` (confirmed absent anywhere today).
   Pinned by a new source-scan test using `FeatureSourceScan.swiftFiles(in:)` + `codeText(of:)`:
   every occurrence of `CNSaveRequest`/`CNMutableContact` in `ios/ElderlyAssistant` must be in
   that one file (`CNContactStore` additionally allowed in `AddressBookDirectory.swift` — read glue).
2. **Intent-record assertion**: the writer builds `PhotoWriteIntent` before the save and
   `assert(intent.fields == [.photo])`; the test fake records the same record type and the
   suite asserts the field-set invariant on every call.
3. **Read-back byte verification**: after `execute`, re-fetch `CNContactImageDataKey` and
   compare bytes with the written JPEG — `.written` requires equality; anything else is
   `.failed(.readBackMismatch)` (never a false success; §10.3's fallback state stands).

Plus the fingerprint re-check AT ATTEMPT TIME (§1.4 step 2): a stale/moved identifier can never
write to a different person — the write is prevented before `execute`.

### 6.3 STRIDE notes for security-design-review

- **Spoofing** (wrong-contact write): fingerprint re-check + read-back + the
  identifier→family uniqueness at link time; a re-used identifier fails the fingerprint, never
  silently redirects.
- **Tampering** (partial/other-field mutation): the request mutates exactly `imageData`
  (intent assertion + confinement + source scan); read-back verifies the outcome.
- **Repudiation**: classification events (§5.2) record refresh/write/unlink/refusal outcomes
  without content.
- **Information disclosure**: nothing new leaves the device (NFR-FCU-003); no log content; the
  photo cache is in-memory only; `PhotoWriteIntent` carries a hash, never bytes.
- **Denial of service**: bounded batches (≤12 identifiers), serial writes, no retries/backoff,
  cache bounded by count+cost; a corrupt payload degrades to unlinked (no crash loop).
- **Elevation of privilege**: the app's only write intent is the edited contact's photo field;
  there is no API surface to write any other field or any other contact.
- Unlink never writes to the system record (FR-FCU-005/FR-FCU-006); the never-lose copy runs
  BEFORE the link clears.

### 6.4 Source-scan pins (new tests)

- `testSystemContactWriteSeamIsTheOnlyCNSaveRequestSite` (§6.2 layer 1).
- `testSyncContactPhotoResolverIsRemoved` — asserts `func contactPhoto(for` no longer exists
  anywhere in `ios/ElderlyAssistant` (the §8.1 deletion is pinned).
- L10n contiguity/coverage pins (§7).
- `FamilyContactWizardSheet` search uses `UnifiedContactSearch` (assert the call string exists
  in SettingsView.swift and the old `SystemContactSearch.search` call is gone from the wizard
  region) — a cheap drift pin for §2.2.
- `ContactsAccess` gate pins (the R1 fix, made able to fail): `ContactsAccessTests` (mapping —
  `.limited` ⇒ `.allowsReading`; `from(_:)` table) and `ContactsAccessGateTests` (per-site
  source pins asserting `allowsReading` present / `== .allowed` absent in each §3.5-enumerated
  expression of LeafViews.swift, SettingsView.swift AND AppCoordinator.swift
  (`refreshNativeMissedCallNames`: :8336 re-read present, :8338 `allowsReading`, :8346
  `access: access`, no hardcoded `.allowed`)).

## 7. Localization — FINAL frozen copy (21 keys)

Structure: 8 `family.link.*` + 7 `family.photo.*` (merged with the 3 existing) + 4
`family.nickname.*` = 19 contiguous `family.*` keys, plus 2 `call.search.*` insertions.
Placeholders: exactly four keys carry one `%@` (`family.link.linkedTo`, `family.link.alreadyLinked`,
`family.nickname.removeLabel`, `call.search.linkedBookName`). No key has any other `%`.

| # | Key | en (FROZEN) | ne (FROZEN) |
|---|---|---|---|
| 1 | family.link.chip | Linked | जोडिएको |
| 2 | family.link.linkedTo | Linked to %@ | %@सँग जोडिएको |
| 3 | family.link.unlink | Remove link | लिंक हटाउनुहोस् |
| 4 | family.link.unlinkHint | This only separates the two records. Nothing is deleted, and your phone's contact is not changed. | यसले दुई रेकर्डलाई मात्र छुट्याउँछ। केही मेटिँदैन, र तपाईंको फोनको सम्पर्क परिवर्तन हुँदैन। |
| 5 | family.link.alreadyLinked | %@ is already a family contact. | %@ पहिले नै परिवारको सम्पर्क हो। |
| 6 | family.link.stale | This phone contact is no longer in your address book. The link is ignored. | यो फोन सम्पर्क अब तपाईंको फोनबुकमा छैन। लिंक बेवास्ता गरिएको छ। |
| 7 | family.link.pickHint | Choose the phone contact this person is in. | यो व्यक्ति फोनमा कुन सम्पर्कको रूपमा छ, त्यो छान्नुहोस्। |
| 8 | family.link.sectionTitle | Phone contact | फोन सम्पर्क |
| 9 | family.photo.accessTitle | Update this person's photo in your phone's contacts? | यो व्यक्तिको फोटो फोनको सम्पर्कमा पनि अपडेट गर्ने हो? |
| 10 | family.photo.accessBody | Allowing contacts access lets the app copy the photo you choose onto this person's contact card. Nothing else in your contacts is changed. The app works fully even if you say no. | सम्पर्क पहुँच अनुमति दिनुभयो भने, तपाईंले छान्नुभएको फोटो यो व्यक्तिको सम्पर्क कार्डमा प्रतिलिपि गर्न सकिन्छ। तपाईंको सम्पर्कमा अरू केही परिवर्तन हुँदैन। तपाईंले नभन्नुभए पनि एप पूरै चल्छ। |
| 11 | family.photo.accessDeniedBody | Contacts access is off, so the photo will be kept in this app only. You can change this in iPhone Settings. | सम्पर्कको पहुँच बन्द छ, त्यसैले फोटो यही एपमा मात्र रहन्छ। तपाईं आईफोनको सेटिङमा यो बदल्न सक्नुहुन्छ। |
| 12 | family.photo.state.updatedInSystem | Photo updated in your phone's contacts. | फोटो फोनको सम्पर्कमा अपडेट भयो। |
| 13 | family.photo.state.keptOnPhone | Kept in this app only. | यही एपमा मात्र राखिएको। |
| 14 | family.photo.state.systemPhotoRemains | Your phone's contact still has its own photo. Change it in the Contacts app to remove it. | तपाईंको फोनको सम्पर्कमा अझै आफ्नै फोटो छ। हटाउन कन्ट्याक्ट्स एपमा गएर बदल्नुहोस्। |
| 15 | family.photo.sourceSystem | Shown from your phone's contacts. | फोनको सम्पर्कबाट देखाइएको। |
| 16 | family.nickname.entryPlaceholder | Add a name or variation (e.g. sanu, सानु) | नाम वा अर्को रूप थप्नुहोस् (जस्तै sanu, सानु) |
| 17 | family.nickname.add | Add | थप्नुहोस् |
| 18 | family.nickname.removeLabel | Remove %@ | %@ हटाउनुहोस् |
| 19 | family.nickname.hint | Any of these names finds this person — typed or spoken. Names are kept exactly as you enter them. | यीमध्ये कुनै नामले यो व्यक्ति भेटिन्छ — टाइप गरेको वा बोलेको। नामहरू तपाईंले लेखेकै रूपमा राखिन्छ। |
| 20 | call.search.linkedBookName | Also in your phone book as %@ | फोनबुकमा %@ को रूपमा पनि छ |
| 21 | call.search.accessLimited | Searching shows only the contacts you allowed. | खोज्दा तपाईंले अनुमति दिनुभएका सम्पर्कहरू मात्र देखिन्छन्। |

Wording notes for the reviewer: #16's ne deliberately contains the romanized example "sanu"
(the store-as-entered showcase) — the ONLY ne value permitted to carry ASCII letters
(documented exception in the coverage function; the Devanagari-presence rule still applies to
it). Every other ne value is pure Devanagari (loanwords transliterated, e.g. कन्ट्याक्ट्स,
फोनबुक, आईफोन, लिंक — matching the dialogue family's convention).

Catalog placement (exact, alphabetical; the file sorts keys case-insensitively as verified):

- `family.link.alreadyLinked`, `family.link.chip`, `family.link.linkedTo`, `family.link.pickHint`,
  `family.link.sectionTitle`, `family.link.stale`, `family.link.unlink`, `family.link.unlinkHint`
- `family.nickname.add`, `family.nickname.entryPlaceholder`, `family.nickname.hint`,
  `family.nickname.removeLabel`
- `family.photo.accessBody`, `family.photo.accessDeniedBody`, `family.photo.accessTitle`,
  (existing) `family.photo.add`, `family.photo.change`, `family.photo.remove`,
  `family.photo.sourceSystem`, `family.photo.state.keptOnPhone`,
  `family.photo.state.systemPhotoRemains`, `family.photo.state.updatedInSystem`
- `call.search.accessLimited` directly BEFORE `call.search.allowBody`;
  `call.search.linkedBookName` between the existing `call.search.familyChip` and `call.search.loadFailed`.

L10n test extension (`L10nCatalogCoverageTests.swift`, the established pin pattern):
- `familyContactsKeys` = the 21 keys; both-languages resolution; values-differ;
  placeholder-count equality (`%` counting); the verbatim `familyContactsCopy` table = the
  rows above; source-catalog coverage via the existing extraction-state checks (both values
  `translated`, ne non-empty + Devanagari, ne ASCII-forbidden with the #16 exemption).
- Contiguity pin (exact span, corrected): the raw catalog key lines between
  `family.emergencyToggleHint` (:5874, predecessor) and `family.relationship.brother`
  (:5942, successor) — both EXCLUDED — must be EXACTLY these 22 lines in order: the 12 new
  family.link./family.nickname. keys, then the 10 family.photo.* keys, which include the 3
  PRE-EXISTING keys at their alphabetical positions (19 new + 3 existing = 22):
  1 family.link.alreadyLinked · 2 family.link.chip · 3 family.link.linkedTo ·
  4 family.link.pickHint · 5 family.link.sectionTitle · 6 family.link.stale ·
  7 family.link.unlink · 8 family.link.unlinkHint · 9 family.nickname.add ·
  10 family.nickname.entryPlaceholder · 11 family.nickname.hint · 12 family.nickname.removeLabel ·
  13 family.photo.accessBody · 14 family.photo.accessDeniedBody · 15 family.photo.accessTitle ·
  16 family.photo.add (pre-existing, :5891) · 17 family.photo.change (pre-existing, :5908) ·
  18 family.photo.remove (pre-existing, :5925) · 19 family.photo.sourceSystem ·
  20 family.photo.state.keptOnPhone · 21 family.photo.state.systemPhotoRemains ·
  22 family.photo.state.updatedInSystem.
  (The rev-1 "19 lines" count omitted the 3 in-place existing keys; the pin now names them
  explicitly so it can actually pass.) Plus two named-neighbor pins for the `call.search.*`
  insertions (accessLimited → allowBody; familyChip → linkedBookName → loadFailed).
- Baseline key-count pin updated DELIBERATELY, count recorded in the test comment: this branch
  measures 1,389 keys before and 1,410 after the 21 insertions (re-measure and record the
  post-call-dialer-merge number at implement time; the +21 delta is the constant, not the absolute).

`Info.plist:115` — replacement `NSContactsUsageDescription` (L1 §12 wording, frozen):

> Searching from the phone screen can call anyone in your phone book — including people added
> by WhatsApp, Messenger and other apps. When you set a photo for a family contact who is also
> in your phone book, the app can save that photo onto the person's contact card if you allow
> it; it changes nothing else. The app works fully even if you say no.

## 8. L1 §19 dispositions and exact placement

### 8.1 `contactPhoto(for:)` — DELETE (decided)

After the four live call sites migrate (`SettingsView.swift:1596`, `:2710`,
`LeafViews.swift:1161`, `:2650` — all become the async face path), `AppCoordinator.contactPhoto(for:)`
(:6492) has ZERO references (verified: comments only). Deleted because: (a) two photo paths
(sync app-local-only vs the async precedence resolver) are the exact drift hazard L1 §10.1
forbids; (b) dead code contradicts house practice; (c) deletion is compile-verified. The
underlying `ContactPhotoStore.load(named:)` STAYS (the resolver's local branch + `loadData`'s
sibling). Pinned by the source-scan test (§6.4).

### 8.2 Placement table (everything new/changed)

| Symbol | File |
|---|---|
| `SystemContactLink`; `FamilyContact.normalizedNicknames`; `LegacyNicknameKeys`; `FamilyContact` schema/decoder | `Services/Storage/FamilyContactStore.swift` |
| `FamilyContactIndex` (+`Entry`, lookups) | NEW `Services/Contacts/FamilyContactIndex.swift` |
| `VerifiedLinksSnapshot` (+ helpers), `SystemContactReading`, `SystemContactLinkReading`, `SystemContactLinkService` | NEW `Services/Contacts/SystemContactLinkService.swift` |
| `SystemContactWriteAccess`, `SystemContactWriteFailure`, `SystemContactPhotoWriteOutcome`, `PhotoWriteField`, `SystemContactPhotoWriting`, `FamilyPhotoEditorState` (+total mapping), `SystemContactPhotoWriter` | NEW `Services/Contacts/SystemContactPhotoWriter.swift` |
| `ContactsAccess.limited`/`allowsReading`/`from(_:)`; `AddressBookDirectory: SystemContactReading`; `fetchKeys` + identifier key; `allEntries` identifier pass-through; `AddressBookEntry.identifier`; `make(..., identifier:)` | `Services/Contacts/AddressBookDirectory.swift` |
| `MissedCallContactResolver.linkedFamilyMatch`, `.limited`-readable `resolve(snapshot:)` | `Services/Contacts/MissedCallContactResolver.swift` |
| `UnifiedContactSearch` signature/Outcome/tier changes (per §1.6) | `Services/Contacts/UnifiedContactSearch.swift` |
| `ContactResolver` index provider + bands + near-miss | `Services/Intents/ContactResolver.swift` |
| `ContactPhotoStore.processedJPEG(_:) -> Data?` (static extraction: `scaledForStorage` → `jpegData`; `save` refactored to call it — byte-identical output) + `loadData(named:)` | `Services/Storage/ContactPhotoStore.swift` |
| Coordinator state, `faceIdentity/faceImage/faceThumbnail`, `SystemContactUnlinkMode`, `unlinkMode`, `setFamilyContactLink`, `syncSystemPhoto`, `refreshVerifiedLinks`, `refreshContactsIdentity`, add/update signatures, link-aware `familyContact(matchingPhone:)` | `App/AppCoordinator.swift` (`familyContact(matchingPhone:)` :8367 delegates to `familyMatch` then `linkedFamilyMatch`; missed-call family pass :8301 uses the same; `refreshNativeMissedCallNames` :8342 passes `verifiedLinks` AND the real access — :8336 status re-read after the prompt, :8338 guard → `allowsReading`, :8346 `access: access`) |
| Wizard restructure (state, subviews, steering, save flow), list chip + face migration, `loadDraft` faces; search access gates → `allowsReading` (`searchSection` switch arm :2117, `refreshSearchAccess` :2325, `grantAccess` :2331) | `App/SettingsView.swift` |
| `CallView` face migration, `UnifiedContactResultRow.caption: String? = nil` + synthesized-row caption render, `ContactTile` face task; CallView `.limited` gates → `allowsReading` (:1343, :1347-1362, :1370, :1379, :1413, :1519) + the `call.search.accessLimited` caption in `searchArea` | `App/LeafViews.swift` |
| `DownsampledImageCache` doc note for the `sysphoto:` key family (no API change) | `App/ViewCaches.swift` |
| 21 keys; `L10nCatalogCoverageTests` pins | `Resources/Localizable.xcstrings`; `ElderlyAssistantTests/App/L10nCatalogCoverageTests.swift` |
| Write disclosure | `Info.plist` (`NSContactsUsageDescription`) |
| `FEATURE_ROOTS` entries | `ios/tools/check-release-log-safety.py` |

### 8.3 Test placement (L1 §17 suites)

- Extended: `FamilyContactStoreTests` (link + nicknames round-trip, legacy lossless, corrupt
  degrade), `UnifiedContactSearchTests` (Passes 1-5, unlinked parity, `linkedBookNames`,
  recount, Devanagari nickname pins positive+negative), `ContactResolverTests` (bands,
  ambiguity consequence table — including the name-exact 1.00 vs nickname-exact 0.85 pair
  explicitly: the IEEE-754 gap is 0.15000000000000002, so the strict `<` margin check resolves
  to name-exact, NOT ambiguous — near-miss), `MissedCallContactResolverTests` (linked-record
  numbers, identifier remap, `.limited`-readable `access:`), `ContactPhotoStoreTests` (`processedJPEG` pins
  + `loadData`), `L10nCatalogCoverageTests`.
- New: `Services/Contacts/FamilyContactIndexTests.swift`,
  `Services/Contacts/SystemContactLinkServiceTests.swift` (fake `SystemContactReading`; the
  §4.2 drain cases: follow-up runs with the latest roster, coalescing, no-trigger-drop),
  `Services/Contacts/SystemContactPhotoWriterTests.swift` (fake writer; intent confinement;
  no-attempt matrix; outcome mapping totality incl. `FamilyPhotoEditorState.from`;
  source-scan pins), `Services/Contacts/ContactsAccessTests.swift` (`from(_:)` table +
  `.limited` ⇒ `.allowsReading` mapping pins), `App/ContactsAccessGateTests.swift` (per-site
  source pins on the §3.5 gate expressions, including
  `AppCoordinator.refreshNativeMissedCallNames`'s :8336 re-read / :8338 guard / :8346
  passthrough).

## 9. Technical risks and mitigations

| # | Risk | Mitigation | Pinning test |
|---|---|---|---|
| R1 | **Identifier instability** — iOS may delete/reissue `CNContact.identifier`s (iCloud merges, restores); a stale link must never call the wrong person | Fingerprint re-check at EVERY use: verification (§6.2 L1) at refresh, attempt-time check before any write; unverified links behave as absent; never auto-removed; `family.link.stale` surfaces the state; the number path (dial/routing) still resolves by NUMBER under the trailing-digit rule | `SystemContactLinkServiceTests` degrade matrix; `UnifiedContactSearchTests` unlinked-pair parity; `SystemContactPhotoWriterTests` no-write-on-mismatch |
| R2 | **Limited access (iOS 18/26)** — granted-subset reads, writes refused for non-granted records, `.limited` currently collapsed into `.denied` by `@unknown default`; equality-based access gates (CallView) compile cleanly and would silently take the else path | `.limited` added end-to-end: readable via `allowsReading` at every ENUMERATED gate (§3.5 — switch arms, equality sites, load gates, grant conditions), never re-prompting; distinct honest caption (`call.search.accessLimited`) on BOTH search surfaces; write detection is attempt-based (`notInGrantedSelection` outcome); UI never claims success or failure it can't verify | mapping pins (`ContactsAccessTests`: `.limited` ⇒ `.allowsReading`, `from(_:)` table; `SystemContactWriteAccess.from` table) + per-site source pins (`ContactsAccessGateTests`: every §3.5 gate asserts `allowsReading` present, `== .allowed` absent — a reverted gate FAILS) + writer outcome matrix |
| R3 | **Unversioned-store migration** — a corrupt/partial payload could crash the boot read or silently drop fields | The optional-field decoder pattern; separate `LegacyNicknameKeys` container keeps the synthesized encoder authoritative; corrupt link fields → nil; decoder pinned by fixtures from every historical shape | `FamilyContactStoreTests` round-trip + legacy blank/whitespace/nil cases + corrupt-link fixture; DV-6 |
| R4 | **Call-dialer union conflicts** — both features touch AppCoordinator/LeafViews/MethodResolver (in flight on master) | Sequence behind its merge (L1 §16); our resolution UPSTREAM (choose the person), their chain DOWNSTREAM (choose the channel) — never inverted; `MethodResolver` untouched; union-preserving edits in shared structs | call-dialer scoped suites + ours on the merged build; manual chain check at DV |
| R5 | **Grapheme pin hazards** — nickname matching must not introduce new Character-cluster behavior (Devanagari partial-word semantics are regression-pinned) | All matching funnels through `NepaliTextNormalizer` + the SAME `range(of:options:)` semantics as today; no new grapheme logic; the new nickname tiers are additive branches gated on non-empty nicknames | `UnifiedContactSearchTests` + `ContactResolverTests` Devanagari pins (positive AND negative), including a Character-cluster partial-word case asserted to behave EXACTLY like the name tier |
| R6 | **Performance budget regression** — index build/query could exceed ≤20 ms at max roster | Precomputed normalized strings, O(1) exact map, ≤108 substring checks; build in one pass; measured assertions with ceilings; the editor caps entries at 8 (tested envelope) | `FamilyContactIndexTests` build ceiling; search/resolve perf tests (measured values recorded) |
| R7 | **Concurrency regressions** — off-main published-state mutation, stale snapshot/face publication, two saves racing one record | Main-confined published state; actor-isolated services; single-flight refresh with latest-roster capture and generation-ordered publication (§4.2); identity-guarded task assignment; strictly serial writes (actor) | `SystemContactLinkServiceTests` coalescing; face identity unit tests; writer serialization test via the fake (no interleaved intents) |
| R8 | **False-success copy** — any path that shows "updated in your phone's contacts" without byte-verified proof | `.written` requires read-back byte equality; every other attempt outcome maps to kept-on-phone copy; the app-local copy is persisted first (never-lose) so the fallback sentence is always true | `SystemContactPhotoWriterTests` read-back mismatch → `.keptOnPhone`; `FamilyPhotoEditorState.from` totality test |

## 10. Traceability additions (beyond L1 §18)

| Requirement | L2 sections |
|---|---|
| FR-FCU-002 (degrade, corruption) | §3.4, §9 R1/R3 |
| FR-FCU-003 (dedupe contract) | §1.6 (Passes 1-5) |
| FR-FCU-004 (one person everywhere) | §1.3, §1.8, §2.2 |
| FR-FCU-005 (unlink never loses) | §1.9 (`unlinkMode`, copy-before-clear), §2.6 |
| FR-FCU-006 (unlink) | §1.9 |
| FR-FCU-008/009/010 (write, authorization, fallback) | §1.4, §1.5, §2.4, §2.6, §6.2, §6.3 |
| FR-FCU-011 (storage/migration) | §3.2, §3.4 |
| FR-FCU-012 (search matching) | §1.6 |
| FR-FCU-013/014 (voice, ambiguity) | §1.7 |
| FR-FCU-015 (editor UI, immediate effect) | §2.5 |
| NFR-FCU-001 (performance) | §6.1 |
| NFR-FCU-002 (PII/log safety) | §5.2, §5.3 |
| NFR-FCU-004 (l10n) | §7 |
| NFR-FCU-005 (a11y) | §2.3, §2.5, §7 |
| NFR-FCU-006 (reliability) | §3.1-§3.4 |
| NFR-FCU-007 (Devanagari pin) | §6.1, §9 R5 |
| NFR-FCU-008 (sequencing) | §9 R4 |
| NFR-FCU-009 (honest gates) | §8.3, §5.3 |
