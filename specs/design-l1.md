# Design L1 — Family Contacts Unify

| | |
|---|---|
| Task | `design-l1` (agent: `system-architect`), contract `architecture_l1` |
| Feature | `family-contacts-unify`, branch `feat/family-contacts-unify` |
| Worktree | `/Users/anjan/workspace/projects/elderly-ai-assistant-family-contacts-unify` |
| Base | master `8089c735` (call-dialer-primary-secondary NOT yet merged — see §16) |
| Date | 2026-10-12 |
| Inputs | `specs/family-contacts-unify/constitution.md`; `specs/define-requirements.md` + `specs/define-requirements/` (17 FR-FCU, 9 NFR-FCU, all MUST); `.ai-sdd/workflows/family-contacts-unify.yaml` scope; project `constitution.md` |
| OD status | Both feature ODs resolved before the run (OD-1 straight to design-l1; OD-2 store-as-entered, no auto-transliteration) |

Line numbers cited below are orientation anchors into base `8089c735`, not contracts; symbol
names are the contracts. This document designs; it does not implement (no production code, no
migrations are written here). Every interface below specifies its error paths (agent principle:
explicit error return types), its isolation (agent principle: concurrency explicit), and adds
no timeouts (agent principle: timeouts are configuration — see §13.4).

---

## 1. Scope and method

This L1 fixes the architecture for the three owner asks — LINK, PHOTO, NICKNAMES — as bound by
the feature constitution's three contracts (Link Identity & Dedupe, Photo Unification, Nickname
& Variation) and the 26 locked requirements. It translates the generic architect template
(REST surface, OpenAPI, Docker topology, auth strategy) to this codebase's idioms:

- **"REST API surface" → the in-process seam surface**: the small set of modules other modules
  may call (Swift protocols/structs with explicit outcome enums), plus the on-device UI seams.
- **"Data model" → the persisted `FamilyContact` schema** and its unversioned-store migration
  contract (decoder defaults; "an optional field IS its migration").
- **"Infrastructure topology" → the process/thread topology**: `@MainActor`-confined
  coordinator state, dedicated actors for the new system-contact IO, pure values everywhere
  else (§13).
- **"Auth strategy" → the Contacts authorization model**, including iOS 18+ `.limited` and the
  honest degraded states, since this feature adds the app's first WRITE into the shared system
  address book (§9.3).

There is no network surface anywhere in this design, by requirement (NFR-FCU-003, §15).

## 2. Feasibility statement (FR-FCU-016)

All three asks are feasible on the target iOS as specified. No silent drops; no ask is
partially answered without being named here.

| Ask | Verdict | What is delivered | Bound / honesty note |
|---|---|---|---|
| LINK | FEASIBLE as specified | `SystemContactLink` stored on `FamilyContact` (§5.1); verified-link snapshot (§6.2); link-aware dedupe for matched AND unmatched queries (§7); every duplicate-render surface audited (§7.3); unlink without touching the system record (§6.4) | Bounded by `CNContact.identifier` stability + fingerprint verification; a stale identifier degrades to unlinked (never a wrong merge), §6.2 |
| PHOTO | FEASIBLE with a stated bound | System photo displayed when present and readable; app writes ONLY the edited contact's photo via confined `CNSaveRequest` (§9); honest full/limited/denied states; app-local `ContactPhotoStore` fallback (owner-pre-authorized) with no loss, no false success, no crash (§10) | Bounded by iOS Contacts authorization: when access is denied/limited-without-grant, the system photo cannot be read or written and the app-local photo stands (today's behavior), explicitly labeled (§10.3). This is the pre-authorized fallback, not a gap |
| NICKNAMES | FEASIBLE as specified | `nicknames: [String]` on `FamilyContact` with lossless legacy migration (§5.2); indexed matching (§5.4); name OR any variant matches in BOTH in-app search (§7.1) and voice (§8.3); ambiguity never silently dials the wrong person (§8.3) | Bounded by OD-2: no automatic transliteration — a variant matches only when recorded (store-as-entered) |

## 3. Architecture overview

```
                 ┌─────────────────────────────────────────────────────────────┐
                 │ AppCoordinator (main-thread confined, ObservableObject)     │
                 │  familyContacts:[FamilyContact]  (EncryptedLocalStorage)    │
                 │  familyIndex: FamilyContactIndex   (derived, rebuilt on μ)  │
                 │  verifiedLinks: VerifiedLinksSnapshot (async refresh)       │
                 │  faceEpoch: UInt64                (photo cache invalidation)│
                 └───────┬──────────────┬───────────────┬──────────────────────┘
                         │              │               │
        ┌────────────────▼──┐  ┌────────▼─────────┐  ┌──▼───────────────────────┐
        │ UnifiedContactSearch│ │ ContactResolver  │  │ MissedCallContactResolver│
        │ (pure enum/struct)  │ │ (pure struct)    │  │ (pure enum)              │
        │ family+book, dedupe │ │ voice scoring    │  │ correlation + dial-back  │
        └───────┬─────────────┘ └──────────────────┘  └──────────────────────────┘
                │
        ┌───────▼─────────────┐        ┌─────────────────────────────┐
        │ AddressBookDirectory│        │ SystemContactLinkService    │  actor
        │ (read-only CNContact│        │  batch verify (identifier + │
        │  Store; entry ident.)│       │  number fingerprint), record│
        └─────────────────────┘        │  numbers, photo data + cache│
                                       └─────────────┬───────────────┘
                                                     │
                                       ┌─────────────▼───────────────┐
                                       │ SystemContactPhotoWriter    │  actor
                                       │  confined CNSaveRequest     │
                                       │  (photo field only) +       │
                                       │  read-back verification     │
                                       └─────────────────────────────┘

UI consumers: FamilyContactsSettingsView (link/photo/nickname editing),
CallView (tiles + result rows + alt caption), CallingSettingsView (untouched,
call-dialer's), MissedCall UI via coordinator.
```

Data flow for the LINK ask: the wizard stores a `SystemContactLink` on save → coordinator
refreshes `VerifiedLinksSnapshot` via `SystemContactLinkService` → every consumer (search,
resolver, missed-call correlation, dial-back) reads the snapshot + `FamilyContactIndex`.
The snapshot is the ONLY place "is this link good right now" is decided, so identity semantics
cannot drift between surfaces.

Data flow for PHOTO: the wizard saves the processed JPEG app-local first (never-lose rule),
then attempts the system write through the writer actor; the outcome drives the honest editor
state (§10.3) and a `faceEpoch` bump; all face display resolves asynchronously through one
coordinator method with system → app-local → initials precedence (§10.1).

## 4. Module boundaries and responsibilities

| File | Status | Responsibility | Requirements |
|---|---|---|---|
| `Services/Storage/FamilyContactStore.swift` | CHANGED | `FamilyContact` gains `systemContact: SystemContactLink?` + `nicknames: [String]`; decoder migration; `normalizedNicknames` helper; `FamilyContactStore` itself unchanged (12-contact cap, storageKey `family.contacts`) | FR-FCU-002, 011; NFR-FCU-006 |
| `Services/Contacts/FamilyContactIndex.swift` | NEW (pure) | Derived search index: normalized names + nicknames, nickname→ids reverse map; rebuilt wholesale on roster mutation | FR-FCU-012; NFR-FCU-001 |
| `Services/Contacts/UnifiedContactSearch.swift` | CHANGED | `FamilyMatchTier` gains `.nickname`; `familyMatches` matches nicknames via the index; new link-aware dedupe pass; `Outcome.linkedBookNames` side table; `moreAvailable` recount | FR-FCU-003, 004, 005, 012 |
| `Services/Contacts/AddressBookDirectory.swift` | CHANGED | `AddressBookEntry.identifier`; `fetchKeys` adds `CNContactIdentifierKey`; `ContactsAccess` gains `.limited` via availability-gated pure mapping `ContactsAccess.from(_:)` | FR-FCU-007, 009 |
| `Services/Contacts/SystemContactLinkService.swift` | NEW (actor) | Batch link verification (identifier fetch + number fingerprint), per-record numbers, system photo data with bounded cache; protocol `SystemContactLinkReading` for tests | FR-FCU-002, 004, 007 |
| `Services/Contacts/SystemContactPhotoWriter.swift` | NEW (actor) | The app's FIRST write seam: `SystemContactPhotoWriting` protocol; real `CNContactStore`/`CNSaveRequest` glue confined to the edited contact's photo; read-back verification; outcome enum | FR-FCU-008, 009, 010 |
| `Services/Intents/ContactResolver.swift` | CHANGED | Nickname scoring bands; near-miss candidate set extended over nicknames; ambiguity semantics unchanged (accept 0.6, margin 0.15) | FR-FCU-013, 014 |
| `Services/Intents/MethodResolver.swift` | UNTOUCHED | Verified: `resolve(contactId:requestedApp:callType:)` (:47) takes an already-resolved contactId; links/nicknames resolve upstream | FR-FCU-005; NFR-FCU-008 |
| `Services/Contacts/MissedCallContactResolver.swift` | CHANGED | Link-aware phone resolution: family phone → linked-record numbers (fingerprint rule reused) → native; native hit remaps to the family person via identifier | FR-FCU-004, 005 |
| `Services/Storage/ContactPhotoStore.swift` | CHANGED (small) | Extract the existing scale/orientation/JPEG pipeline as `static func processedJPEG(_:) -> Data?` so app-local and system copies are the SAME bytes (one encode, two destinations) | FR-FCU-010; NFR-FCU-003 |
| `App/AppCoordinator.swift` | CHANGED | `nicknames` in add/update signatures; verified-links snapshot lifecycle; email-like minimal searchText policy unchanged; `faceIdentity(for:)` + async `faceImage/faceThumbnail(for:)`; write orchestration; unlink API | all |
| `App/SettingsView.swift` | CHANGED | Wizard find step hosts link UI (no new step, "Step N of 5" untouched); photo step gains access card + honest outcome labels; nickname step becomes a managed list; family row link chip | FR-FCU-001, 006, 009, 010, 015 |
| `App/LeafViews.swift` | CHANGED | `CallView` face resolution via the async coordinator path; `UnifiedContactResultRow` gains optional `caption` (alt caption); `ContactTile` same face path | FR-FCU-003, 005, 007 |
| `App/ViewCaches.swift` | CHANGED (small) | `DownsampledImageCache` keyed by face identity string (`sysphoto:<id>:<hash-prefix>` / `contact:<filename>`); existing budget unchanged | NFR-FCU-001 |
| `App/CallingSettingsView.swift` | UNTOUCHED | call-dialer territory (NFR-FCU-008) | — |
| `Resources/Localizable.xcstrings`, `App/L10n.swift`, `ElderlyAssistantTests/.../L10nCatalogCoverageTests.swift` | CHANGED | ~20 new keys en+ne; pinned-key suite extended | NFR-FCU-004 |
| `Info.plist` | CHANGED | `NSContactsUsageDescription` gains the photo-updating disclosure | FR-FCU-009 |
| `ios/tools/check-release-log-safety.sh(.py)` | CHANGED (registration) | New write/link seam files registered with the stricter "feature" role | NFR-FCU-002 |

## 5. Data model

### 5.1 `SystemContactLink` on `FamilyContact`

```swift
/// A pointer to one record in the system address book, with the fingerprint
/// needed to prove it is still the same person. Local-only; never transmitted.
struct SystemContactLink: Codable, Equatable {
    var identifier: String   // CNContact.identifier at link time
    var numberKey: String    // ContactNumberKey.normalized of the FIRST dialable
                             // number of the picked entry at link time
}
```

- `FamilyContact` gains `var systemContact: SystemContactLink?` (default nil) and
  `var nicknames: [String]` (§5.2). Both are covered by the custom decoder at
  `FamilyContactStore.swift:122-150` using the established pattern
  `(try? container.decodeIfPresent(...)) ?? nil` — an absent key, wrong type, or unknown shape
  decodes to "unlinked / no nicknames". There is no store version field and none is added
  (unversioned payload; the optional field IS its migration; NFR-FCU-006, DV-6).
- Corrupt/empty link fields (empty `identifier` or `numberKey`) decode to `nil` — FR-FCU-002
  scenario 3 turns "corrupt payload" into "unlinked", never a crash and never a merge.
- Encoding uses the synthesized `Encodable`; nil optionals are omitted (encodeIfPresent), so a
  pre-feature payload → new build → save produces a clean payload with `systemContact` present
  only when linked.
- The link is written ONLY by the wizard save path (§11.1) and removed only by unlink (§6.4).
  It never stores a photo, a name, or a number list — the fingerprint is one normalized digit
  string (the same shape already stored in `phone`), so it adds no new PII class (§15).

### 5.2 Multi-nickname model + migration

- `FamilyContact.nickname: String?` (currently :71) is REPLACED by `var nicknames: [String]`.
  No computed `nickname` shim is kept — one source of truth; all readers migrate (§18 call
  inventory: `SettingsView.swift:2690`, `AppCoordinator.swift:6578`,
  `ProfileInterviewSteps.swift:530-541` pass-through).
- Decode contract (lossless, FR-FCU-011, NFR-FCU-006, DV-6):
  1. If `nicknames` decodes to `[String]` → use it, after `normalizedNicknames` (trim each;
     drop empty/whitespace-only entries; preserve order and duplicates as entered).
  2. Else if the legacy `nickname` key decodes to a non-blank `String` → `[thatValue]`
     (trimmed). A legacy blank/whitespace-only value → `[]`.
  3. Else `[]`.
  Implementation note: the legacy key is read through a SEPARATE private
  `keyedBy: LegacyNicknameKeys` container so `CodingKeys` contains only stored properties and
  the synthesized encoder stays authoritative.
- Explicitly REJECTED: a mirrored legacy `nickname` key on encode (downgrade builds would read
  it). It would require a hand-written `encode(to:)`, which risks silently dropping a field on
  save — a data-loss hazard directly against NFR-FCU-006 — for a downgrade convenience nothing
  requires. The synthesized encoder is kept; downgrade reads simply show no nickname.
- Whitespace-only entries are never stored (FR-FCU-011): enforced at entry, at
  `normalizedNicknames` on decode, and at the save path.
- No auto-transliteration anywhere (OD-2): "sanu" and "सानु" are distinct entries.

### 5.3 `AddressBookEntry.identifier`

`AddressBookEntry` gains `let identifier: String` (default `""` in `make(...)`/init to keep
test construction trivial). `AddressBookDirectory.fetchKeys` (:333) adds
`CNContactIdentifierKey` and `allEntries()` (:386) passes `contact.identifier` through. All
matching logic (`SystemContactSearch.matches`) is unchanged. Linking is available only for
entries with a non-empty identifier (a defensive `canLink` guard; real store fetches always
populate it). No persistence of book entries exists anywhere, so no migration applies.

### 5.4 `FamilyContactIndex` (pure) — the nickname index

```swift
/// Derived, value-type index over the family roster. Rebuilt wholesale on every
/// roster mutation; never persisted; never mutated in place.
struct FamilyContactIndex: Equatable {
    struct Entry: Equatable {
        let id: UUID
        let normalizedName: String        // NepaliTextNormalizer.normalize
        let normalizedNicknames: [String] // per entry, order preserved
    }
    private(set) var entries: [Entry]                 // roster order preserved
    private(set) var idsByNickname: [String: [UUID]]  // normalized exact key → ids

    init(family: [FamilyContact])
    func nicknameEntries(for id: UUID) -> [String]
    func exactNicknameHolders(_ normalizedQuery: String) -> [UUID]
}
```

- Structure: precomputed normalized strings (one `NepaliTextNormalizer.normalize` pass per
  name/nickname at build) + a reverse exact-key map for O(1) "which contacts hold this exact
  nickname". Substring/containment checks still run Character-safe
  `range(of:options:[.caseInsensitive, .diacriticInsensitive])` over the normalized strings
  (no new grapheme logic; NFR-FCU-007).
- Maintenance: published by the coordinator as `@Published private(set) var familyIndex`;
  rebuilt inside every mutation path (`addFamilyContact`, `updateFamilyContact`,
  `removeFamilyContact`, the launch batch load :3957) — the same places that mutate
  `familyContacts`. Because the rebuild is wholesale, drift is impossible; because it derives
  only from `familyContacts`, it can never disagree with the store.
- Cost: one build ≈ 12 contacts × (1 name + ≤8 nicknames) = ≤108 normalizations (measured
  sub-millisecond); query side is exact-map lookups plus ≤9 substring checks per contact. At
  empty nicknames it degenerates to exactly today's name-only behavior.
- Empty index (no nicknames) reproduces today's behavior byte-for-byte — the compatibility
  anchor for "unlinked pairs keep today's behavior exactly".

## 6. Link identity contract (FR-FCU-001, 002, 004, 005, 006)

### 6.1 Creation and uniqueness

- Created in the wizard's find step (in-app search, §11.4): picking a result row stores
  `SystemContactLink(identifier: entry.identifier, numberKey: entry.normalized)` in the draft;
  committed with Save. Not stored for un-saved drafts, never inferred, never auto-created.
- One family contact per system record: the wizard detects an identifier already linked to
  another family contact and steers instead of creating a second record (§11.1); the
  coordinator's add/update guard re-checks and refuses to persist a duplicate claim
  (defense in depth).
- At most one link per family contact (single optional field; replacing a link is a normal
  update — the old claim is simply replaced).

### 6.2 Verification and degradation (identifier stability)

- `SystemContactLinkService.refresh(contacts:)` (actor) performs ONE batched fetch
  (`unifiedContacts(matching: predicate by identifier, keysToFetch: [CNContactIdentifierKey,
  CNContactPhoneNumbersKey])`, ≤12 identifiers) and, per link:
  - **verified** iff a record with that identifier exists AND any of its current normalized
    numbers satisfies `MissedCallContactResolver.matches(storedNumberKey, current)` (the
    existing trailing-digit rule, floor 8). Number ADDED/kept → verified; number changed or
    record gone → NOT verified.
  - Duplicate identifier claims (only possible from a corrupt payload): first claim in roster
    order wins the snapshot; later duplicates are treated as unverified, reason-coded.
- Snapshot published on main as `VerifiedLinksSnapshot { links: [UUID: SystemContactLink],
  linkedRecordNumbers: [String: [String]], generation: UInt64 }`, `.empty` default. Every
  consumer reads only the snapshot. **Empty snapshot ⇒ today's behavior exactly.**
- Refresh triggers: roster mutation; launch/foreground; Contacts access change; after a
  successful photo write (numbers unchanged, so links hold; generation bumps for cache/UI
  identity); verification epoch bump. Single-flight: at most one refresh runs; a trigger while
  one is in flight sets a dirty flag and re-runs after — latest snapshot wins (deterministic;
  §13.2).
- Unverified links are NOT auto-removed. Display/search/dedupe treat them as absent
  (unlinked semantics); the wizard shows the stale-link line (`family.link.stale`) so the owner
  can unlink or re-link. Never a crash, never a merge (FR-FCU-002 scenario 3).

### 6.3 Link-aware number reach

`linkedRecordNumbers` (all current normalized numbers of each verified linked record) is a
first-class input to `MissedCallContactResolver` (§7.3, §8) so a call from a linked person's
book-record number resolves to the FAMILY person — the "number of either side resolves to the
one family contact" invariant of FR-FCU-004. The existing number-format tolerance
(`matches`/`digits()`) is reused unchanged.

### 6.4 Unlink (FR-FCU-006)

- The wizard's link area offers `family.link.unlink` with `family.link.unlinkHint` ("This only
  separates the two records. Nothing is deleted, and your phone's contact is not changed.").
- `AppCoordinator.setFamilyContactLink(id:mode:)` with
  `enum SystemContactUnlinkMode { case unlinkKeepingLocalAsIs, unlinkKeepingDisplayedPhotoLocally,
  unlinkAndClearAppLocalPhoto }`:
  - `unlinkKeepingLocalAsIs` (default): clears `systemContact`; app-local file untouched.
  - `unlinkKeepingDisplayedPhotoLocally`: offered when the current display source is the
    SYSTEM photo and no app-local file exists — copies the already-fetched system bytes into
    `ContactPhotoStore` (one encode via `processedJPEG`), then clears the link. No loss of the
    photo the owner is looking at.
  - `unlinkAndClearAppLocalPhoto`: clears the link and the app-local file (explicit choice).
- Unlink NEVER writes to the system record, never deletes the system contact, works for
  unverified/stale links, and bumps the face epoch + verification epoch. Wrong-person remedy =
  unlink + re-link (documented in the editor help line): even a mistaken link cannot dial a
  person the owner cannot reach; it only changes which stored name/routing the app applies,
  and unlink restores.

## 7. Link-aware dedupe contract (FR-FCU-003, 004, 005)

### 7.1 Rules

Inputs: `query`; roster + `FamilyContactIndex`; `entries` (with identifiers); `verifiedLinks`
snapshot; `recency`. Output: `Outcome { results: [Result], moreAvailable: Bool,
linkedBookNames: [String: String] }`.

- **Pass 1 — family matches (widened by nicknames):** `familyMatches(query:family:index:)`
  keeps today's tiers and adds nickname tiers per §8.1. `matchedFamily` = matched contacts.
- **Pass 2 — book matches (unchanged):** `SystemContactSearch.matches` over entries.
- **Pass 3 — link pass (NEW):** for each matched book row `b` whose `b.identifier` equals the
  verified link of some family contact `f` (unique by §6.2):
  - `f ∈ matchedFamily` → DROP `b` (the family row is the person).
  - `f ∉ matchedFamily` (query matched only the book-side name or number spelling) →
    SYNTHESIZE a family row for `f` (tier `.containment`, id `family-<uuid>`) and DROP `b`;
    record `linkedBookNames["family-<uuid>"] = b.displayName` (suppressed when equal to the
    family name after normalization).
- **Pass 4 — today's number rule (UNCHANGED, applied to remaining book rows):** drop any
  remaining book row whose normalized number equals a matched family row's normalized number.
  After Pass 3 the remaining linked book rows are gone, so this rule now fires only for
  UNLINKED pairs — byte-for-byte today's behavior (C6 exactness).
- **Pass 5 — recount:** `results` = family group (matched + synthesized), then book group
  (existing `rank`/order semantics; rawValue quality order auto-sorts `.nickname` correctly);
  `moreAvailable` is recomputed on the post-pass row count before the limit slice — dropping
  linked twins can turn `moreAvailable` false (FR-FCU-003 scenario 4).

Correctness notes: digit queries with differently spelled numbers for a linked pair
("+977-98…" vs "98…") now dedupe by identifier (Pass 3), not by number equality — one row
(FR-FCU-003 scenario 3). Unmatched-query/empty-query rendering is untouched (no rows are
produced from a non-matching query, so "one row per linked person for matched AND unmatched
queries" holds trivially, and the steady-state CallView renders family tiles once per family
record). Unlinked pairs take identical code paths to today because every new branch is gated
on a verified link.

### 7.2 Representation and the alt caption

- `Result` enum arity is NOT changed (protects the call-dialer union, §16). The alt caption
  travels in the new `Outcome.linkedBookNames: [String: String]` (family result id → phone-book
  display name), default `[:]`.
- `UnifiedContactResultRow` gains `caption: String? = nil`; `CallView` looks up
  `outcome.linkedBookNames[entry.id]` and renders `call.search.linkedBookName`
  ("Also in your phone book as %@") for synthesized rows. Honest UI: the row explains why a
  name the user did not type into the family record appears.
- A synthesized row carries the family phone (dial, channels, photo all take the family path).

### 7.3 Surface audit — where the pair could render twice

| Surface | Today | With a verified link |
|---|---|---|
| `CallView` search results (`resultsArea`, LeafViews.swift:1680) | family row + book row when querying the book-side spelling/number | ONE row (§7.1 Pass 3) |
| `CallView` family tiles (`familyArea`, :1741, `ContactTile` :2572) | one tile per family record | unchanged — one family record exists (write-side uniqueness §6.1); book never renders here |
| Voice resolution (`ContactResolver`) | family-only candidates | unchanged candidate set; nickname tiers added (§8) — a name/nickname/relationship yields ONE candidate |
| Missed-call name correlation (AppCoordinator `refreshMissedCallCorrelations` :8294, `refreshNativeMissedCallNames` :8327) | native hit shows the book name even when the family person is the same human | native hit whose identifier is a verified link remaps to the FAMILY name (`MissedCallContactResolver` link-aware, §6.3) |
| Missed-call dial-back (`familyContact(matchingPhone:)` :8367, `missedCallDialAction` :8423, `dialBackMissedCall` :8457) | family phone only | family phone → linked-record numbers → native; the chosen FamilyContact is the ONE person (§6.3) |
| Wizard search (find step) | family + book rows | same `UnifiedContactSearch` dedupe + already-linked steering (§11.1) |
| Settings family list (SettingsView) | one row per family record | unchanged; link chip added; corrupt duplicate links show an unlinkable state, never hidden records (§6.2) |
| Call-confirmation dialog / dialing | resolved family contact | unchanged (single contact) |
| `ProfileInterviewSteps` kin list | family-only | unchanged |

## 8. Name / nickname resolution — match order, voice bands, ambiguity (FR-FCU-012, 013, 014)

### 8.1 Tier order (search side)

`FamilyMatchTier` (UnifiedContactSearch.swift:155; rawValue IS quality order) gains `.nickname`
between `.relationship` and `.containment`:

| Tier | rawValue | Matches on |
|---|---|---|
| `.exactName` | 0 | normalized name == normalized query |
| `.relationship` | 1 | existing relationship-anchor logic (unchanged) |
| `.nickname` | 2 (NEW) | any stored nickname: exact or Character-safe substring |
| `.containment` | 3 (was 2) | name containment / digit containment (unchanged logic) |

Within `.nickname`: exact > substring. Sort/rank logic is rawValue-based and needs no other
change; exhaustive switches over the enum are updated at implement (grep — rank + tests).
Tier is transient (never persisted), so renumbering is safe.

### 8.2 Normalization reuse (pin)

All new matching funnels through `NepaliTextNormalizer.normalize` and Character-safe
substring comparison exactly as today — no fork, no transliteration, no grapheme "fixes"
(NFR-FCU-007, OD-2). Devanagari nickname/substring behavior gets regression tests (positive
and negative pins) rather than corrections.

### 8.3 Voice bands and ambiguity (ContactResolver)

Scoring bands (replacing/extending the table at ContactResolver.swift:93; accept 0.6 and
ambiguity margin 0.15 remain the private constants at :61-62):

| Band | Score | Condition |
|---|---|---|
| exact name | 1.00 | normalized equality |
| relationship | 0.90 | relationshipAnchor (unchanged) |
| exact nickname | 0.85 | any nickname normalized-equal (NEW) |
| name containment | 0.80 | unchanged |
| nickname containment | 0.75 | NEW |
| near-miss (typo) | 0.60 | edit distance ≤2 over name OR nickname |

- Ambiguity rule unchanged: top−runner < 0.15 ⇒ ambiguous (never guess). Consequence table:
  name-exact vs nickname-exact gap 0.15 ⇒ resolves to the NAME-exact person (name exact stays
  strongest); nickname-exact vs relationship (0.05), vs name containment (0.05), vs another
  nickname-exact (0.0), vs nickname containment (0.10) ⇒ ALL ambiguous — two people sharing a
  nickname, or a nickname colliding with a weaker signal, never silently dials (FR-FCU-014).
- Ties are ambiguity, not order — determinism comes from the comparison, not from roster
  order.
- Near-miss extension: candidate set = contacts whose name OR any nickname is within edit
  distance 2 of the query; the existing exactly-one-in-budget rule (budget 2) is preserved —
  if a name-near-miss and a nickname-near-miss both land in budget, there are two candidates
  and the near-miss path abstains (existing behavior shape).
- The linked system twin is never a candidate (ContactResolver consults the family roster
  only), so a linked pair can produce at most ONE spoken confirmation by construction
  (FR-FCU-004 scenario 2).
- `ContactResolver` init gains an index provider (`indexProvider: (() -> FamilyContactIndex)?`
  with nil ⇒ build internally from the contacts provider on the fly, pure) so tests keep
  compiling and the hot path uses the published index.

### 8.4 Performance budget and measurement (NFR-FCU-001)

- Targets at max roster (12 contacts × 8 nicknames, Devanagari included): family-half search
  ≤20 ms per keystroke; voice `resolve()` ≤20 ms per utterance. Budgets hold because build is
  O(roster×nicknames) once per mutation and queries are exact-map + short substring scans over
  precomputed normalized strings (strictly cheaper per query than today's per-call
  normalization of names alone).
- Verification: measured XCTest perf tests (§17) with assertion ceilings; measured values are
  logged in the test output and recorded at the DV step. No production timer or timeout is
  introduced (§13.4).

## 9. System-contact WRITE seam (FR-FCU-008, 009, 010)

### 9.1 Interfaces and error paths (first-class)

New file `Services/Contacts/SystemContactPhotoWriter.swift`:

```swift
enum SystemContactWriteAccess: Equatable {
    case notDetermined, denied, limited, full
}

enum SystemContactWriteFailure: String {        // reason codes only — log-safe (§15)
    case fetchFailed, notInGrantedSelection, saveRejected, readBackMismatch
}

enum SystemContactPhotoWriteOutcome: Equatable {
    case written                                   // saved AND verified by read-back
    case skippedNoLink                             // unlinked/unverified → no attempt (today's behavior)
    case skippedNoAuthorization(SystemContactWriteAccess)
    case recordGone                                // identifier no longer resolves
    case identityMismatch                          // fingerprint failed at attempt time
    case failed(SystemContactWriteFailure)
}

protocol SystemContactPhotoWriting: AnyObject {
    func writeAccess() async -> SystemContactWriteAccess        // detected, never assumed
    func writePhoto(_ jpeg: Data, to link: SystemContactLink) async -> SystemContactPhotoWriteOutcome
    func clearPhoto(from link: SystemContactLink) async -> SystemContactPhotoWriteOutcome
}
```

Every seam call returns an outcome value — no throwing, no silent failure; the actor may not
crash the app (no `try!`; `CNSaveRequest.execute` `throws` is caught and mapped). The
outcome→UI mapping is total (§10.3).

### 9.2 Real glue: confined `CNSaveRequest` + read-back verification

`actor SystemContactPhotoWriter: SystemContactPhotoWriting` — the ONLY file permitted to
touch `CNSaveRequest`/`CNMutableContact` (new files; confirmed absent anywhere today):

1. `writeAccess()` → availability-gated pure mapping (§9.3). No prompt is ever triggered from
   here — prompting is a deliberate user action in the editor's ask card (§11.1).
2. `writePhoto(jpeg, link)`:
   - fetch by identifier with keys `[CNContactIdentifierKey, CNContactPhoneNumbersKey,
     CNContactImageDataKey, CNContactImageDataAvailableKey]`; fetch failure → `.fetchFailed`
     (under limited access, a not-granted record fails here → `.notInGrantedSelection`);
     empty result → `.recordGone`.
   - fingerprint re-check at attempt time (same `matches` rule) → mismatch → `.identityMismatch`
     (a wrong-contact write is prevented, not just detected).
   - `mutable = contact.mutableCopy() as! CNMutableContact`; assign ONLY `imageData` (the
     already-processed JPEG bytes from `ContactPhotoStore.processedJPEG` — same bytes the
     app-local store holds); `CNSaveRequest().update(mutable)`; `execute` in `do/catch` →
     `.saveRejected`.
   - read-back: re-fetch `CNContactImageDataKey`; byte equality → `.written`; else
     `.readBackMismatch` (never a false success; the fallback state stands).
   - Confinement is enforced three ways: request built only inside this file; intent record
     asserts the field set (below); source-review in security-design-review + security-test.
3. `clearPhoto(from:)` — same sequence with `imageData = nil`.
4. Serialization: actor isolation makes writes strictly serial; one write at a time
   (≤12 linked contacts; typically one per Save).

`SystemContactLinkService` (actor, `Services/Contacts/SystemContactLinkService.swift`)
implements `SystemContactLinkReading`:

```swift
struct VerifiedLinksSnapshot: Equatable {
    var links: [UUID: SystemContactLink]
    var linkedRecordNumbers: [String: [String]]
    var generation: UInt64
    static let empty = VerifiedLinksSnapshot(links: [:], linkedRecordNumbers: [:], generation: 0)
}

protocol SystemContactLinkReading: AnyObject {
    func refresh(contacts: [FamilyContact]) async -> VerifiedLinksSnapshot
    func photoImageData(forIdentifier id: String) async -> Data?   // nil: absent/unreadable
    func invalidate(identifier: String?)                           // one record, or all
}
```

It caches system photo bytes keyed by identifier with a bounded in-memory guard (cache
wholesale-invalidated on foreground and on our own writes; constants finalized in L2). Read
access is checked BEFORE any fetch; `.denied`/`.notDetermined` ⇒ no store call, snapshot
survives unchanged.

### 9.3 Authorization model (full / limited / denied — detected, not assumed)

- Pure mappings, testable without a store instance:
  - `ContactsAccess.from(_ status: CNAuthorizationStatus) -> ContactsAccess` — adds
    `.limited` (iOS 18+) via `if #available(iOS 18.0, *)`; `@unknown default` → `.denied`.
  - `SystemContactWriteAccess.from(_ status:) -> SystemContactWriteAccess` — same shape;
    `.authorized → .full`, `.denied/.restricted → .denied`, `.limited → .limited` (gated),
    `@unknown → .denied`.
- `AddressBookDirectory.access()` (:348) currently funnels `.limited` into `@unknown default →
  .denied`, so iOS 18/26 limited users are treated as denied on BOTH read and write. This
  design deliberately adds `.limited` to `ContactsAccess` and treats `.allowed` and `.limited`
  as readable (`allowsReading` helper) with a distinct honest access-card copy; this is a
  minimal supporting change so that "system photo displayed when present" is true for a
  granted contact under limited access, and search shows the granted set instead of claiming
  the book is off. Denial/nagging logic continues to key on `.denied` only — limited never
  re-prompts.
- Prompting: only via the editor's photo-step ask card (point of use, plain language, §11.1)
  calling the existing `requestAccess()`; iOS 18 may return `.limited` from that flow — both
  statuses proceed to attempt-and-detect. No prompt from search or display paths.
- Write detection is attempt-based even under `.full`: every outcome comes from the store's
  actual response (fetch/save/read-back), never from the status alone. A read-only/restricted
  save → `.saveRejected` → fallback state; nothing is claimed that did not happen.

### 9.4 Test double + intent record

`FakeSystemContactPhotoWriter: SystemContactPhotoWriting` records
`PhotoWriteIntent { identifier: String, fields: Set<PhotoWriteField> /* invariant == [.photo] */,
imageBytesHash: String /* sha256 prefix — never the bytes */ }` and returns scripted outcomes.
Tests assert: field-set invariant (photo only), fingerprint precondition (no write on
mismatch), no attempt on unlinked/denied, and the outcome→state mapping (§17). The fake is
injected through the same protocol the coordinator holds, so no test touches `CNContactStore`.

## 10. Photo display precedence and the fallback state machine (FR-FCU-007, 010)

### 10.1 Precedence resolver (async, honest)

One coordinator entry point; UI never computes precedence in `body`:

```swift
func faceImage(for contact: FamilyContact) async -> UIImage?   // UIImage? = show initials
func faceThumbnail(for contact: FamilyContact, diameter: CGFloat, displayScale: CGFloat) async -> UIImage?
func faceIdentity(for contact: FamilyContact) -> String        // ".task(id:)" key
```

Resolution order per call: (1) verified link + readable access + `photoImageData` succeeds →
SYSTEM photo; (2) app-local `photoFilename` loads → app-local; (3) nil ⇒ existing initials
avatar. Any failure at a step degrades to the next — a tile is never blank (FR-FCU-010
no-crash/no-loss). `faceIdentity` = `"<id>:<sysphoto-hash or link-nil>:<filename>:
<faceEpoch>"` so `.task(id:)` re-runs exactly on link/photo/epoch changes. Thumbnails go
through `DownsampledImageCache` keyed `sysphoto:<identifier>:<sha256-prefix>` or
`contact:<filename>` (same budget; two sources can never collide). The three current
app-local-only call sites (SettingsView.swift:1592, LeafViews.swift:1157, :2646) migrate to
this method; the old sync `contactPhoto(for:)` remains only if still referenced (L2 detail).
The editor additionally shows `family.photo.sourceSystem` when the displayed photo is the
system one — the only surface that needs the label (FR-FCU-007 honest display).

### 10.2 Editor save flow (write sequencing)

1. Existing sync store write runs FIRST (unchanged semantics: failure keeps the draft,
   `SettingsView.swift:2762-2776`). The processed JPEG is persisted app-local in the same
   write — the picked photo can never be lost to a later system-write failure (FR-FCU-010).
2. If the store write succeeded AND a NEW/CHANGED photo exists AND the contact is linked
   (verified) → attempt in a `Task`: notDetermined/denied → `.skippedNoAuthorization`
   (fallback state, no prompt); else `writePhoto(jpeg, to:)` with the same processed bytes.
3. `.written` → bump `faceEpoch`, invalidate the identifier's photo cache, dismiss (today's
   UX). Any other outcome → set the outcome state (§10.3), KEEP the sheet open, and switch the
   primary button to Done (auto-dismiss only on success). The owner sees exactly what
   happened; nothing is claimed that did not happen.
4. No photo changed → dismiss as today; no write attempted.

### 10.3 Fallback / degradation state machine

| Condition | Attempt? | Outcome | Editor state (label) | Display afterwards |
|---|---|---|---|---|
| Unlinked/unverified link | no | `.skippedNoLink` | none (today's behavior) | app-local or initials |
| Access `.notDetermined` | no (ask card offers Allow) | `.skippedNoAuthorization(.notDetermined)` | `family.photo.state.keptOnPhone` | app-local |
| Access `.denied` | no | `.skippedNoAuthorization(.denied)` | `family.photo.state.keptOnPhone` + `family.photo.accessDeniedBody` | app-local |
| Access `.limited`, record not granted | yes → fetch fails | `.notInGrantedSelection` | `family.photo.state.keptOnPhone` | app-local |
| Record vanished since verification | yes | `.recordGone` | `family.photo.state.keptOnPhone`; link will degrade on next refresh (§6.2) | app-local |
| Fingerprint mismatch at attempt | yes (prevented) | `.identityMismatch` | `family.photo.state.keptOnPhone`; wizard shows stale-link line | app-local |
| Save rejected (read-only etc.) | yes | `.failed(.saveRejected)` | `family.photo.state.keptOnPhone` | app-local |
| Save ok, read-back differs | yes | `.failed(.readBackMismatch)` | `family.photo.state.keptOnPhone` (never false success) | system fetch decides; else app-local |
| Success + verified | yes | `.written` | `family.photo.state.updatedInSystem` | SYSTEM photo (identical bytes to what was picked) |

### 10.4 Remove semantics

Existing three-state draft (picked / removingStored / untouched) is preserved. On a successful
store update with removal: app-local deleted (today) AND, if linked+verified+writable, a
best-effort `clearPhoto` runs; if a system photo still remains (clear skipped or failed — e.g.
the record's photo was not ours or save was rejected), the editor shows
`family.photo.state.systemPhotoRemains` (honest, actionable in the Contacts app). Unlinked →
today's behavior exactly, no label.

## 11. UI surfaces

### 11.1 Family editor wizard (`FamilyContactWizardSheet`, SettingsView.swift:1529ff)

- Steps stay five; the indicator ("Step N of 5") is untouched. Link UI lives INSIDE the find
  step; nickname management inside the nickname step.
- Find step: in-app search results gain a linked-state affordance. Tapping a result for a
  contact already linked to ANOTHER family contact does not select it — it shows
  `family.link.alreadyLinked` + the existing contact as entry to its editor (steering).
  Tapping an unlinked result selects it as today AND records the link in the draft;
  `family.link.linkedTo` shows the chosen book name with an unlink action
  (`family.link.unlink`/`family.link.unlinkHint`). A stale/unverified link renders
  `family.link.stale`. `family.link.pickHint` labels the affordance. No link is stored until
  Save. Pre-filled edits of an already-linked contact show the link area pre-populated.
- Photo step: existing `PhotosPicker` + `displayedPhoto` (picked > stored) behavior unchanged;
  adds (a) source caption `family.photo.sourceSystem` when displaying the system photo;
  (b) the write-access card when linked and access is `.notDetermined` (`family.photo.accessTitle`
  /`family.photo.accessBody`, Allow reusing `call.search.allowButton`, decline = continue with
  fallback); (c) `family.photo.accessDeniedBody` line when `.denied` (no nag; Open Settings
  reuses the existing link); (d) outcome state labels per §10.3.
- Nickname step: replaces the single `TextField` (:2575) with a managed list — chips/rows of
  saved entries each with a remove control (≥44 pt, a11y label `family.nickname.removeLabel`),
  plus an add field (`family.nickname.entryPlaceholder`) + Add button (`family.nickname.add`),
  hint `family.nickname.hint` (covers store-as-entered). `normalizedNicknames` filters
  whitespace-only entries at save; saving with the list unchanged is a no-op for the store.
  Changes take effect immediately after Save (index rebuild on the roster mutation; no
  restart — FR-FCU-015). Removal is a save-time edit like every other field.
- Save path signatures: `addFamilyContact(..., nicknames: [String] = [], ...)` (defaulted —
  onboarding/ProfileInterview callers unchanged) and `updateFamilyContact(..., nicknames:
  [String], ...)` — REQUIRED (no default) so no caller can silently wipe the list; the two
  existing callers are updated: ProfilesInterviewSteps:530-541 passes
  `entry.contact.nicknames` through; the wizard passes the draft.

### 11.2 Family list and settings

Family rows gain a compact link chip (`family.link.chip`) and use the new async face path.
No new screen; no reordering. Kin/emergency surfaces untouched (out of scope).

### 11.3 Call surfaces

`CallView` tiles and result rows migrate to `faceThumbnail` (§10.1) and render
`linkedBookNames` captions (§7.2). Zoom/layout untouched; `UnifiedContactResultRow` gains
only `caption: String? = nil`. This is the exact seam contact with call-dialer (§16): their
dial-layer edits and our face/caption layer coexist in the same structs without redesign.

### 11.4 Pick mechanism: in-app search over `CNContactPickerViewController`

DECISION: in-app search (existing wizard pattern). Rationale: (1) linking requires the
`CNContact.identifier` and ONGOING read access for verification, photo read/write, and dedupe
across surfaces — the system picker grants per-pick access without a persistent identifier
fetch story, so it cannot support §6.2 verification; (2) the already-linked steering (§11.1)
needs result rows the picker does not offer; (3) the wizard's search + access cards are
already localized, accessible, and test-covered; (4) `CNContactPickerViewController` would be
a third interaction paradigm in one sheet. Rejected accordingly (the picker remains
`NSContactsUsageDescription`-covered but unused).

## 12. Localization and permission disclosure (NFR-FCU-004, FR-FCU-009)

New keys (all en + ne, added to `Resources/Localizable.xcstrings`, resolved via `L10n.str`):

| Key | en (intent; final wording frozen in L2) | Placeholders |
|---|---|---|
| `family.link.chip` | Linked | — |
| `family.link.linkedTo` | Linked to %@ | 1 |
| `family.link.unlink` | Remove link | — |
| `family.link.unlinkHint` | This only separates the two records. Nothing is deleted, and your phone's contact is not changed. | — |
| `family.link.alreadyLinked` | %@ is already a family contact. | 1 |
| `family.link.stale` | This phone contact is no longer in your address book. The link is ignored. | — |
| `family.link.pickHint` | Choose the phone contact this person is in. | — |
| `family.link.sectionTitle` | Phone contact | — |
| `family.photo.accessTitle` | Update this person's photo in your phone's contacts? | — |
| `family.photo.accessBody` | Allowing contacts access lets the app copy the photo you choose onto this person's contact card. Nothing else in your contacts is changed. The app works fully even if you say no. | — |
| `family.photo.accessDeniedBody` | Contacts access is off, so the photo will be kept in this app only. You can change this in iPhone Settings. | — |
| `family.photo.state.updatedInSystem` | Photo updated in your phone's contacts. | — |
| `family.photo.state.keptOnPhone` | Kept in this app only. | — |
| `family.photo.state.systemPhotoRemains` | Your phone's contact still has its own photo. Change it in the Contacts app to remove it. | — |
| `family.photo.sourceSystem` | Shown from your phone's contacts. | — |
| `family.nickname.entryPlaceholder` | Add a name or variation (e.g. sanu, सानु) | — |
| `family.nickname.add` | Add | — |
| `family.nickname.removeLabel` | Remove %@ | 1 (a11y) |
| `family.nickname.hint` | Any of these names finds this person — typed or spoken. Names are kept exactly as you enter them. | — |
| `call.search.linkedBookName` | Also in your phone book as %@ | 1 |
| `call.search.accessLimited` | Searching shows only the contacts you allowed. | — |

`L10nCatalogCoverageTests` is extended with a pinned `familyContactsKeys` array + the existing
both-languages / values-differ / placeholder-count tests, following the established pattern
(baseline key-count pin is updated deliberately with the count recorded).

`Info.plist` (:115) `NSContactsUsageDescription` gains the write disclosure (plist-only; no
`InfoPlist.strings` exists in this project — all usage strings are English-only today, kept
consistent):

> Searching from the phone screen can call anyone in your phone book — including people added
> by WhatsApp, Messenger and other apps. When you set a photo for a family contact who is also
> in your phone book, the app can save that photo onto the person's contact card if you allow
> it; it changes nothing else. The app works fully even if you say no.

## 13. Concurrency and isolation (explicit)

### 13.1 Matrix

| Component | Isolation | Concurrent access |
|---|---|---|
| `AppCoordinator` state (`familyContacts`, `familyIndex`, `verifiedLinks`, `faceEpoch`) | main thread (existing `ObservableObject` confinement) | UI + `Task { @MainActor }` continuations |
| `FamilyContactIndex`, `UnifiedContactSearch`, `ContactResolver`, `MissedCallContactResolver`, `NepaliTextNormalizer` | pure values/stateless — safe anywhere | called from main; no shared mutable state |
| `SystemContactLinkService` | actor | serialized verification/photo reads; concurrent callers await; internal cache behind the actor |
| `SystemContactPhotoWriter` | actor | writes strictly serialized (one `CNSaveRequest` at a time) |
| `DownsampledImageCache` | existing `NSCache` (thread-safe) | unchanged |

### 13.2 Single-flight and ordering rules

- Link verification: at most ONE in-flight refresh; concurrent triggers set a dirty flag and
  coalesce into one follow-up run; the latest snapshot wins (generation-monotonic).
- Face resolution: idempotent async reads; stale completions are dropped by comparing
  `faceIdentity` before applying (the `.task(id:)` pattern's cancel/re-run semantics do the
  rest).
- Write path: Save orchestrates store-write → local file → system attempt sequentially inside
  one `Task`; the actor additionally serializes across saves. No parallel writes to one
  record.
- UI state (outcome labels, sheets) is only mutated on main.

### 13.3 Shared-state rules

No new global mutable state; the snapshot and the index are the ONLY derived state consumers
read (single decision point). Pure types take inputs explicitly — no ambient singletons in
the decision cores (house seam pattern).

### 13.4 Timeouts

No timeouts, retries, or delays are introduced. There is no network and no blocking call on
the main thread; `CNContactStore` offers no timeout knob, so exposure is bounded structurally
(≤12 identifiers per batch, fetch only for visible/linked rows, no loops or backoff). Should
a wait ever be needed, it must be a named configurable constant routed through the existing
configuration surface — never a literal (inherited agent principle). None is needed now.

## 14. Error-path catalogue

| Interface | Failure | Returned outcome | Consumer behavior |
|---|---|---|---|
| `FamilyContactStore` load (decode) | corrupt link/nickname shapes | `nil` / `[]` (decode-degrade) | unlinked/no-nickname semantics; no crash |
| `FamilyContactStore` save | storage failure | existing `Bool` false | draft kept (today) |
| `UnifiedContactSearch` | never throws | pure values | n/a |
| `SystemContactLinkReading.refresh` | fetch/authorization failure | previous snapshot survives (per-link degrade) | unverified links treated as absent |
| `photoImageData(forIdentifier:)` | absent/unreadable | `nil` | next display precedence step |
| `SystemContactPhotoWriting.writeAccess` | unknown status | `.denied` mapping (`@unknown default`) | fallback state, no attempt |
| `writePhoto/clearPhoto` | fetch/save/read-back failures | typed `SystemContactPhotoWriteOutcome` (never throws) | §10.3 mapping (total) |
| `requestAccess` | iOS returns limited | `.limited` | proceed to attempt-and-detect |
| Coordinator link write (duplicate claim) | guard refusal | `Bool` false + reason-coded log | wizard steering shown; nothing persisted |

## 15. PII, log safety, no egress, release gate wiring (NFR-FCU-002, 003)

- Reason codes only: outcome enums (`SystemContactWriteFailure` raw values, degrade reasons)
  may be logged; names, numbers, identifiers, image bytes, and nicknames NEVER reach logs or
  diagnostics beyond the existing transcript policy (B2/T-050). `PhotoWriteIntent.imageBytesHash`
  is a hash, by construction.
- No new egress: every seam is on-device (`CNContactStore` is the system address book on the
  same device); no new network client, no analytics, no new collection (NFR-FCU-003). The
  processed JPEG pipeline strips source image metadata (existing behavior, now shared by the
  system write).
- `ios/tools/check-release-log-safety.sh(.py)` walks the entire `ios/ElderlyAssistant` tree
  already; the two NEW seam files (`SystemContactPhotoWriter.swift`,
  `SystemContactLinkService.swift`) are added to `FEATURE_ROOTS` (stricter "feature" role),
  and the fixture suite must keep passing unchanged. The gate stays wired into `ios/build.sh`
  ahead of every test scope.

## 16. Call-dialer union and sequencing plan (NFR-FCU-008)

Process gate: implementation merges master ONLY after `call-dialer-primary-secondary`'s PR
has merged. First implementation step verifies the merge landed (call-dialer's merge commit
present on master AND `Services/Calls/CallChannelChain.swift` exists), then merges master into
`feat/family-contacts-unify` BEFORE any conflicted-file work. If call-dialer has not merged,
implementation waits — no parallel edit of the same surfaces.

| File | call-dialer's change | Our change | Union rule |
|---|---|---|---|
| `Services/Intents/MethodResolver.swift` | adds its global-default step / chain consultation | NONE (verified: `resolve(contactId:...)` already takes the resolved id) | keep theirs intact |
| `App/AppCoordinator.swift` | `resolvedCallChannel`/`resolvedMissedCallChannel` chain + `secondaryCallApp` | link-aware `familyContact(matchingPhone:)` upstream + snapshot lifecycle | our lookup feeds their chain, unchanged; never inline their chain into ours |
| `App/LeafViews.swift` | row dial layer / whatsApp probe delegation (~:1171-1174) | face path + `caption` param on the same structs | both layers coexist; their dial code untouched by us, our face/caption code untouched by them |
| `App/CallingSettingsView.swift` | Primary/Fallback pickers | NONE | theirs only; we do not touch |
| Tests | their suites | our suites | disjoint; both run post-merge |

Post-merge regression: run call-dialer's scoped suites AND ours; manually re-check the
chain still fires (their DV class) on the merged build. Semantic conflict rule if their
refactor moved `familyContact(matchingPhone:)`: our link-aware resolution must sit UPSTREAM
(choose the person), their chain DOWNSTREAM (choose the channel) — never the reverse.

## 17. Test plan and gates (NFR-FCU-009, FR-FCU-017)

- Extended suites: `FamilyContactStoreTests` (link + nicknames round-trip; legacy single
  nickname lossless; corrupt payload degrade), `UnifiedContactSearchTests` (Pass 1-5 rules;
  unlinked pairs exactly today's results; digit-spelling dedupe; `linkedBookNames`;
  `moreAvailable` recount; Devanagari substring pins positive+negative), `ContactResolverTests`
  (band table; ambiguity consequences; near-miss extension; determinism),
  `MissedCallContactResolverTests` (linked-record numbers; identifier remap),
  `ContactPhotoStoreTests` (extracted `processedJPEG` pins preserved),
  `L10nCatalogCoverageTests` (new keys both languages).
- New suites: `FamilyContactIndexTests` (build/mutate/delete; nickname exact/substring;
  Devanagari; max-roster build ≤20 ms), `SystemContactPhotoWriterTests` (fake writer: intent
  confinement `[.photo]`; no-attempt matrix; outcome mapping is total),
  `SystemContactLinkServiceTests` (verification degrade matrix via injected directory fake;
  duplicate-claim uniqueness; empty snapshot ⇒ unlinked semantics).
- Performance: search ≤20 ms and `resolve()` ≤20 ms at 12×8 roster with assertion ceilings;
  measurements recorded.
- Device gate FR-FCU-017: DV-1 … DV-6 on Anzaan, recorded with the feature spec. Release gate:
  `check-release-log-safety.sh` exits 0 (§15).
- Honesty: scoped tests per unit; full suite once at the end; any baseline failures recorded
  with attribution (master currently carries known pre-existing failures — do not mask).

## 18. Traceability

| Requirement | Sections |
|---|---|
| FR-FCU-001 link add flow, one person everywhere | 5.1, 6.1, 7, 11.1 |
| FR-FCU-002 storage & migration, local-only, degrade | 5.1, 6.2, 15 |
| FR-FCU-003 search/dedupe contract | 7.1, 7.2, 7.3 |
| FR-FCU-004 identity across surfaces (incl. voice "one confirmation") | 6.3, 7.3, 8.3, 11.3 |
| FR-FCU-005 call list / cross-surface | 7.3, 11.2, 11.3 |
| FR-FCU-006 unlink | 6.4, 11.1 |
| FR-FCU-007 display precedence (system photo) | 10.1, 11.3 |
| FR-FCU-008 write path confined to edited contact's photo | 9.1, 9.2 |
| FR-FCU-009 authorization full/limited/denied, disclosure, no nag | 9.3, 11.1, 12 |
| FR-FCU-010 fallback & degradation | 10.2, 10.3, 10.4, 14 |
| FR-FCU-011 nickname storage & migration | 5.2 |
| FR-FCU-012 nickname search matching | 5.4, 7.1, 8.1, 8.2 |
| FR-FCU-013 nickname voice resolution | 8.3 |
| FR-FCU-014 ambiguity safety | 8.3 |
| FR-FCU-015 nickname editor UI, immediate effect | 11.1 |
| FR-FCU-016 feasibility honesty | 2 |
| FR-FCU-017 DV gate | 17 |
| NFR-FCU-001 performance (≤20 ms) | 5.4, 8.4, 17 |
| NFR-FCU-002 PII / log safety | 9.1, 9.4, 15 |
| NFR-FCU-003 no egress / no new collection | 3, 8, 15 |
| NFR-FCU-004 localisation ne/en | 12 |
| NFR-FCU-005 accessibility (targets, labels) | 11.1, 12 |
| NFR-FCU-006 reliability / lossless migration | 5.1, 5.2, 6.2, 14 |
| NFR-FCU-007 Devanagari pin, no "fixes" | 8.2, 17 |
| NFR-FCU-008 sequencing | 16 |
| NFR-FCU-009 honest gates | 16, 17 |

## 19. Deferred to design-l2

- Component-level breakdown of the wizard sheet restructure (state flow, subviews) and of the
  coordinator's new methods; exact file/symbol placement of `normalizedNicknames`.
- Final en/ne wording for the §12 keys (keys fixed here; wording frozen with the L10n tests).
- Cache constants for `SystemContactLinkService.photoImageData` (capacity/eviction) and the
  worker's exact retry-free sequencing around refresh epochs.
- The already-linked steering micro-flow (tap targets, back-navigation into the other
  contact's editor).
- Whether the now-unreferenced sync `contactPhoto(for:)` is deleted or retained.
- Verification scheduling details (launch/foreground hook ordering); a11y labels per control.
- Unit/task decomposition and wave ordering (plan-tasks follows approval of this design).

## 20. Assumptions

- A1: Reference device Anzaan runs iOS 26-class, so `.limited` is reachable; deployment target
  iOS 16 means every `.limited` reference is availability-gated (compiled against the current
  SDK).
- A2: No `requirements.md` exists for this feature; the constitution + locked requirement set
  are the inputs (index.md of the requirements folder).
- A3: `FamilyContact` payloads are unversioned; the optional-field decoder pattern remains the
  migration mechanism (verified in existing code).
- A4: Book rows (non-family results) keep today's initials avatar; photo unification is a
  family-contact concern (recorded scope assumption).
- A5: The call-dialer branch remains design-only until its implementation and merge land;
  §16's process gate re-verifies at implementation start.
