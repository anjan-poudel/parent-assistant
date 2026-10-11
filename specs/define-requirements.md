# Requirements — Family Contacts Unify (feature)

**Project:** Elderly AI Assistant · **Feature:** `family-contacts-unify` (v1) ·
**Branch:** `feat/family-contacts-unify` (worktree `elderly-ai-assistant-family-contacts-unify`;
scaffold base master `8089c735`)
**Task:** `define-requirements` (agent `ba`; contracts `requirements_doc` + `requirements_lock`)
**Date:** 2026-10-12 · **Status:** submitted for owner HIL approval (risk tier T1, per the
feature workflow's `define-requirements` task). The owner's 2026-10-12 request is settled input
and both Open Decisions were resolved before the first run; the locked snapshot in
`define-requirements.lock.yaml` is the drift-detection baseline.

This is the consolidated, human-readable copy of the feature requirements. The structured source
of the same set is the folder [`define-requirements/`](define-requirements/index.md): one file
per requirement, with index files at each level. Both are generated from the same content; the
per-requirement files are the unit of change, this document plus the lock file are the snapshot
downstream tasks (`design-l1`, `design-l2`, `review-l2`, `security-design-review`, `plan-tasks`,
`implement`, `review-implementation`, `security-test`, `final-sign-off`) consume.

**ID convention.** Requirement IDs are namespaced `FR-FCU-NNN` / `NFR-FCU-NNN`. The project-level
stakeholder brief (`requirements.md`) already uses the bare `FR-NNN` / `NFR-NNN` series, so a
feature-scoped namespace avoids collisions in downstream traceability — the same convention
live-camera-translation used (`FR-LCT-NNN`), profile-interview used (`FR-PI-NNN`),
spotify-music-integration used (`FR-SP-NNN`) and multi-turn-conversation used (`FR-MTC-NNN`).
One file per requirement; every requirement carries at least one Gherkin scenario, and every
safety-relevant requirement carries a failure scenario.

**Stakeholder brief.** There is no `requirements.md` for this feature. The stakeholder input is
the owner request 2026-10-12 (recorded in the feature constitution "Source of truth" and
distilled in the workflow scope comment): family and other contacts are duplicated in the app;
(1) search a system contact and add it as a family contact; (2) when setting a contact's
picture, update the system contact's photo and pull photos from system contacts for display,
falling back to the app-local photo when the system record is not updatable; (3) multiple
nicknames/name variations per family contact (e.g. sanu, syanu, Devanagari forms), indexed,
matched by name OR any nickname/variation in search and voice resolution — with "if not
feasible, tell the owner" (feasibility honesty is itself a requirement, FR-FCU-016).

**Scope summary.** 17 functional requirements (`FR-FCU-001` … `FR-FCU-017`, all MUST) and 9
non-functional requirements (`NFR-FCU-001` … `NFR-FCU-009`, all MUST). The three asks with their
pre-authorized feasibility fallbacks: LINK (one person everywhere; link-aware dedupe beyond
today's matched-only normalized-number rule; unlinked pairs keep today's behavior exactly),
PHOTO (the app's first write into the system address book, confined to the edited contact's
photo; honest authorization states; the app-local `ContactPhotoStore` fallback with no loss, no
false success, no crash), NICKNAMES (multiple variants stored as entered — no automatic
transliteration — indexed, matched in BOTH in-app search and voice resolution through the
existing matching semantics; the grapheme behavior regression-pinned; an ambiguous nickname
never silently dials the wrong person). Completion gate: DV-1 … DV-6 on the reference device
(Anzaan), recorded with the feature spec (FR-FCU-017).

**Relationship to `call-dialer-primary-secondary`.** Explicitly distinct, in flight; this
feature must not absorb, redesign or merge its scope. Implementation queues behind its PR merge
(NFR-FCU-008). Expected conflicts (`MethodResolver.swift`, `LeafViews.swift`,
`AppCoordinator.swift`, `CallingSettingsView.swift`) are resolved as a union preserving
call-dialer's behavior.

---

## Functional requirements

### FR-FCU-001: Link a system contact as a family contact (the LINK flow)

**Area:** Link / Add Flow · **Priority:** MUST
**Source:** Owner request 2026-10-12, ask 1; feature constitution Feature Purpose & Scope and
Link Identity & Dedupe Contract binding property 1; workflow `define-requirements` scope comment.
Surfaces: `FamilyContactsSettingsView` (`SettingsView.swift:1529`), `AddressBookDirectory`
(`ContactsAccess` :245, read-only sweep `allEntries()` :386), `FamilyContactStore`.

The family contact editor **must** let the family member search the system address book and add
a found system contact as a family contact whose stored record carries an explicit LINK to that
system record. Binding properties: the pick produces exactly one family contact carrying the
link (from creation, the pair is one person); search reuses the existing system-contact read
path with today's honest point-of-use permission handling; family fields remain the app's own
data (prefill design-level); a system contact already linked to an existing family contact must
not be linked a second time (no two identity records for one system record); when the address
book cannot be consulted (denied/not determined) the flow shows the honest state, degrades to
today's manual entry, and writes no phantom link; the link is stored under the house migration
rule (FR-FCU-002).

```gherkin
Feature: Add a system contact as a family contact (link)

  Scenario: Search, pick, and add a system contact as a linked family contact
    Given Contacts access allows reading the address book
    And a system contact "सीता शर्मा" exists with no family contact yet
    When the family member searches "सीता" in the family editor's add flow and picks the contact
    Then exactly one family contact is created carrying a stored link to that system record
    And the person appears once in the call list and in search results

  Scenario: An already-linked system contact cannot be linked twice
    Given a system contact is already linked to an existing family contact
    When the family member searches for it in the add flow
    Then no second family contact claiming that system record is created
    And the flow steers to the existing family contact instead

  Scenario: Address book unavailable — honest state, no phantom link (failure)
    Given Contacts access is denied or not determined
    When the family member opens the add flow
    Then the honest permission state is shown, with the point-of-use request where applicable
    And today's manual entry remains available
    And no link is stored
```

**Related:** FR-FCU-002/003/004/005/006/015 · NFR-FCU-002/005/006.

### FR-FCU-002: Link reference storage with legacy-safe migration

**Area:** Link / Storage & Migration · **Priority:** MUST
**Source:** Feature constitution Link property 5 and Feature Constraint 2; surface:
`FamilyContactStore` (`FamilyContact` :61, custom decoder :122-150, unversioned store — "an
optional field IS its migration").

The link reference **must** be stored on the `FamilyContact` record under the house migration
rule: new field(s) optional; the custom decoder reads a missing key as "unlinked" (a pre-link
payload loads unlinked instead of failing the read); save/load round-trips preserve the link and
every other field; the reference shape (e.g. `CNContact.identifier` stability) is design-l1's to
settle — the stored value survives the encrypted round-trip and a lookup failure is handled per
FR-FCU-006; a corrupt/unknown value degrades to "unlinked" (never a failed read, never a crash);
the link is local-only (NFR-FCU-003).

```gherkin
Feature: Link reference storage and migration

  Scenario: A linked contact round-trips through the encrypted store
    Given a family contact linked to a system record
    When it is saved and loaded again
    Then the link is intact
    And every other field is unchanged

  Scenario: A pre-link payload loads as unlinked
    Given a store payload written before the link field existed
    When the store is read
    Then the contact loads unlinked
    And no read fails and no contact is lost

  Scenario: A corrupt link value degrades to unlinked (failure)
    Given a payload whose link value is unreadable or unknown
    When the store is read
    Then the contact loads as unlinked
    And the read succeeds with all other fields intact
```

**Related:** FR-FCU-001/003/005/006 · NFR-FCU-003/006.

### FR-FCU-003: Link-aware dedupe — one row for a linked person in unified search

**Area:** Search / Dedupe · **Priority:** MUST
**Source:** Feature constitution Link properties 1–3 and Feature Constraint 6; surfaces:
`UnifiedContactSearch` (matched-only dedupe :269, `FamilyMatchTier` :155, `familyMatches` :217).

`UnifiedContactSearch` dedupe **must** become link-aware beyond today's matched-only
normalized-number rule: an explicit link is identity evidence independent of number spelling; a
query matching EITHER side of a linked pair yields exactly one row for that person (matched AND
unmatched queries); the person stays findable by whatever matched; **unlinked pairs keep today's
behavior EXACTLY** (an unmatched family twin must not hide the book twin; number-only matches do
not become more aggressive); which single representation the row renders is design-level.

```gherkin
Feature: Link-aware dedupe in unified search

  Scenario: Family-side match hides the linked book twin
    Given a family contact linked to a system record of the same person
    When the user searches a query that matches the family record
    Then exactly one row for that person is returned
    And the linked book twin does not appear as a second row

  Scenario: Book-side-only match still yields one row
    Given a linked pair where the query matches only the book side (e.g. the book record's name)
    When the search runs
    Then exactly one row for that person is returned
    And the person is findable by the book-side match

  Scenario: A digit query finds the linked person once despite differing number spellings
    Given a linked pair whose numbers are spelled differently ("+977-98…" vs "98…")
    When the user searches a digit run of either spelling
    Then exactly one row for that person is returned

  Scenario: Unlinked pairs keep today's matched-only behavior (regression)
    Given an unlinked family contact and a book record with the same number
    When a query matches the book record but NOT the family contact
    Then the book row still appears — the unmatched family twin must not hide it
    And the existing matched-only normalized-number dedupe applies exactly as today
```

**Related:** FR-FCU-001/004/005/006/012 · NFR-FCU-001/002.

### FR-FCU-004: One person across every people surface — call list, voice resolution, missed-call correlation

**Area:** Identity / Cross-surface · **Priority:** MUST
**Source:** Feature constitution Link property 1 and Feature Constraint 6; surfaces: `CallView`
(`LeafViews.swift:918`; family rows :1747; `UnifiedContactResultRow` :2288), `ContactResolver`,
`MissedCallContactResolver` ("Number→person correlation must respect links so dial-back renders
one person").

A linked pair **must** render and resolve as ONE person in every surface that shows or resolves
people: unified search (FR-FCU-003); the call list (one tile/row; double-linking prevented at
creation); voice call resolution (name/nickname/relationship/number of either side resolves to
the one family contact — the twin creates no spurious rival and there is exactly one
confirmation); missed-call correlation (a missed call from either side's number correlates to
the one person; dial-back names the person once; the correlation reaches the linked person even
when the dialed number is the system record's). No surface may reintroduce a duplicate for a
linked pair.

```gherkin
Feature: One person across every people surface

  Scenario: The call list shows the linked person once
    Given a system contact is linked as a family contact
    When the call list is displayed
    Then the person appears exactly once in the family rows
    And no book twin of the same person is presented as a second person

  Scenario: Voice resolution reaches the one linked person, not a rival twin
    Given a family contact linked to a system record of the same person
    When the user says "call <name of either side>"
    Then the one family contact is resolved
    And exactly one confirmation is spoken — the system twin creates no ambiguity

  Scenario: A missed call from the system record's number dials back as the one person
    Given a linked pair
    And a missed call recorded from the system record's number
    When the missed call is displayed
    Then it names the one linked person
    And dial-back targets that one person, not a second entry
```

**Related:** FR-FCU-001/003/013/014 · NFR-FCU-002/009.

### FR-FCU-005: Unlink — reversible, with both records intact

**Area:** Link / Unlink · **Priority:** MUST
**Source:** Feature constitution Link property 4, Open Decisions note (unlink semantics
design-level), Safety & Compliance Delta (Identity integrity). Mechanics/UI design-level; the
safety invariants bind.

The link **must** be removable, as the safety valve for a wrong link: unlinking never deletes or
edits the system record (no `CNSaveRequest`; byte-unchanged) and never deletes the family
contact's data (the family record remains fully usable); after unlink the pair reverts to
today's behavior exactly (matched-only dedupe; no identity claim); unlinking is lossless and
reversible; a wrongly merged pair can be separated with no data lost on either side.

```gherkin
Feature: Unlink

  Scenario: Unlink restores today's separate-records behavior without data loss
    Given a linked family contact and system record
    When the family member removes the link
    Then the family contact remains, fully usable, with all its fields intact
    And the system record is unchanged (no write is issued)
    And search behavior for the pair is exactly today's unlinked behavior

  Scenario: A wrong link is repaired by unlinking (safety)
    Given two different people were wrongly linked (a mis-link)
    When the family member unlinks them
    Then the two records are separate again with no data lost from either side
    And no identity claim remains between them
    And the system record was never modified
```

**Related:** FR-FCU-001/002/003/006 · NFR-FCU-002.

### FR-FCU-006: Stale or broken link degradation — never hide, never crash, never strand a call

**Area:** Link / Degradation · **Priority:** MUST
**Source:** Feature constitution Link property 4, Safety & Compliance Delta; workflow
`security-design-review` focus (identity integrity).

A stale, broken or mismatched link **must** degrade to today's behavior — never worse: a deleted
system record leaves the family contact fully usable everywhere; a re-synced/re-created record
or an identifier that now resolves to a different person **must not merge two different people**
(an unverifiable/mismatched link is treated as absent for identity/dedupe; design may verify
identity evidence before trusting a link — the binding result is no false merge); identifier
lookup failures at any surface (including permission states) are treated as unlinked for that
surface; never crashes, never hides the person, never strands a call.

```gherkin
Feature: Stale or broken link degradation

  Scenario: The linked system record was deleted
    Given a family contact linked to a system record that no longer exists
    When the person is searched, called by voice, or dialed from the call list
    Then the family contact behaves exactly as a family contact with no link
    And nothing crashes and no call path is stranded

  Scenario: The stored identifier now resolves to a different person (failure)
    Given a link whose stored reference no longer corresponds to the linked person
    When the identity is resolved
    Then the two people are NOT merged into one
    And behavior for both degrades to today's unlinked behavior
    And no wrong-person resolution or dedupe occurs

  Scenario: Identifier lookup fails at resolve time
    Given a link that cannot be looked up in the current moment (e.g. permission state)
    When a surface resolves or displays the pair
    Then the surface falls back to today's behavior
    And no error is surfaced to the user
```

**Related:** FR-FCU-002/003/004/005 · NFR-FCU-002/009.

### FR-FCU-007: Photo display precedence — system photo, then app-local, then initials

**Area:** Photo / Display · **Priority:** MUST
**Source:** Owner request ask 2; feature constitution Photo contract property 3 and Success
Criteria; DV-3. Surfaces: `AppCoordinator.contactPhoto(for:)` (:6492), `ContactPhotoStore`,
`ContactTile` / `UnifiedContactResultRow` / editor rows (`DownsampledImageCache`), `FaceAvatar`.

Wherever the app displays a family contact's face, the displayed photo **must** follow the
precedence: (1) the system contact's photo when present and readable; (2) else the app-local
`ContactPhotoStore` thumbnail (`photoFilename`); (3) else the existing initials avatar. Applies
to a family contact with an established system counterpart (the linked record; number-match
extension for unlinked contacts is design-level). The display reflects the current photo on
refresh, reusing the existing downsampling path; missing/unreadable/removed system photos fall
back silently — never an error state. Non-family book rows keep today's initials avatar.

```gherkin
Feature: Photo display precedence for family contacts

  Scenario: The system contact's photo wins when present
    Given a linked family contact whose system record has a photo
    And the family contact also has an app-local photo
    When the family row/tile is displayed
    Then the system contact's photo is shown

  Scenario: No system photo — the app-local photo is shown
    Given a linked family contact whose system record has no photo
    And the family contact has an app-local photo
    When the family row/tile is displayed
    Then the app-local photo is shown (today's behavior preserved)

  Scenario: Neither photo exists — the initials avatar is shown
    Given a family contact with no system photo and no app-local photo
    When the family row/tile is displayed
    Then the existing initials avatar is shown
    And no error or placeholder failure state appears
```

**Related:** FR-FCU-008/009/010 · NFR-FCU-002/005.

### FR-FCU-008: Photo write confined to the edited contact's photo

**Area:** Photo / Write Path · **Priority:** MUST (safety-critical)
**Source:** Owner request ask 2; feature constitution Photo contract properties 1 and 5 and
Feature Constraint 5; workflow `security-design-review` focus (write authority blast radius).
Surfaces: no `CNSaveRequest` exists in the app today — new injectable write seam (design-l1);
family editor photo setter (`PhotosPicker` :2485, picked-photo load :2511); `ContactPhotoStore`.

When a photo is set for a family contact whose system record is writable and linked, the app
**must** update ONLY that one system contact's photo: `CNContactStore`/`CNSaveRequest` confined
to the edited contact's own linked record (one contact at a time, never a bulk rewrite, never
another contact; wrong-target writes prevented by construction); no other field of the system
record is ever modified; the write carries photo data only while the app-local write continues
on today's path; a failed/rejected write is a no-op on the system side (never a partial
mutation); no system write for an unlinked contact (today's behavior exactly); the seam is
injectable for tests.

```gherkin
Feature: Photo write confined to the edited contact

  Scenario: Setting a photo updates only that contact's photo on the system side
    Given a linked family contact whose system record is writable
    When the family member sets or changes the contact's photo
    Then the added system record is exactly the edited contact's linked record
    And it carries only the photo change — verified by read-back
    And the app-local photo is stored as today

  Scenario: The save touches no other contact and no other field (confinement)
    Given any photo set through the editor
    When the resulting save request is inspected in tests
    Then it targets exactly one contact — the edited contact's linked record
    And it contains only the photo field
    And no bulk or multi-contact mutation exists

  Scenario: A failed write is a no-op on the system side (failure)
    Given a writable-looking system record and a save that fails
    When the failure occurs
    Then the system record is unchanged — no partial mutation, no corruption
    And the app-local photo is intact

  Scenario: An unlinked contact never triggers a system write
    Given a family contact with no link
    When the family member sets a photo
    Then the photo is stored app-local exactly as today
    And no system write is attempted
```

**Related:** FR-FCU-002/007/009/010 · NFR-FCU-002/009.

### FR-FCU-009: Write authorization — full, limited and denied are all honest states, detected not assumed

**Area:** Photo / Authorization · **Priority:** MUST (safety-critical)
**Source:** Feature constitution Photo contract property 2 and Feature Constraints 4–5; Safety &
Compliance Delta (write authority); workflow `security-design-review`/`security-test` focus.
Surfaces: `ContactsAccess` (:245; `.restricted` → `.denied`), `Info.plist`
`NSContactsUsageDescription` (:115 — read/search-oriented copy must gain the write disclosure);
family editor photo setter; project constitution (point-of-use permissions with plain-language
explanation).

The write path **must** handle authorization honestly: permission requested at the point of use
(family editor photo setter) with plain-language explanation; full / limited (selected-contacts)
/ denied / restricted / read-only are all honest states with per-record writability DETECTED,
not assumed; the app never claims an unverified write succeeded ("updated" only after
confirmation); `NSContactsUsageDescription` honestly discloses the photo-updating use when the
write surface ships; the elderly user is never asked to reason about address-book authorization
(any explanation lives in the family member's editor); denial is never nagged.

```gherkin
Feature: Honest authorization states for the photo write

  Scenario: Limited access with the edited contact writable
    Given Contacts access is limited to selected contacts
    And the edited contact is among the visible, writable ones
    When a photo is set
    Then the write proceeds and success is only shown once the save is confirmed

  Scenario: Limited access with the edited contact not writable
    Given Contacts access is limited and the edited contact is not writable under it
    When a photo is set
    Then the contact is detected as non-writable — not assumed
    And the app-local fallback applies per FR-FCU-010
    And no false success is shown

  Scenario: Access denied — no nagging, honest fallback (failure)
    Given Contacts access is denied or restricted
    When a photo is set
    Then no write is attempted or claimed
    And no repeating permission prompt is shown
    And the app-local fallback applies per FR-FCU-010

  Scenario: An unverified save is never presented as success
    Given a save the system does not confirm
    When the photo flow completes
    Then the app does not claim the system contact was updated

  Scenario: The permission copy discloses the photo-updating use
    Given the write surface ships
    When the Contacts permission prompt is read
    Then its copy plainly describes reading/searching and updating a contact's photo
```

**Related:** FR-FCU-007/008/010 · NFR-FCU-002/005/009.

### FR-FCU-010: Non-writable fallback — no loss, no false success, no crash

**Area:** Photo / Fallback & Degradation · **Priority:** MUST (safety-critical)
**Source:** Feature constitution Photo contract properties 4 and 6, Feature Constraint 4
(pre-authorized fallback); DV-4; workflow `security-test` focus.

When the system contact is not writable — permission denied, limited access without this
contact, read-only record, save failure — **or there is no link at all**: the picked photo stays
app-local exactly as today (`ContactPhotoStore` `photoFilename`; non-throwing best-effort stack
preserved); the photo is never lost and the UI never claims an unverified success; the failure
is a no-op on the system side (FR-FCU-008) and produces no failure dialog for the elderly user;
no crash, no thrown error; display per FR-FCU-007 (app-local photo, else initials); the fallback
is a labeled state in the editor and silent/neutral on the parent's surfaces; a later photo set
with writable access can update the system record (retroactive push design-level).

```gherkin
Feature: App-local fallback when the system contact is not writable

  Scenario: Write access denied — the picked photo stays app-local, nothing lost
    Given a linked contact whose system record is not writable (denied/limited/read-only)
    When the family member sets a photo
    Then the photo is stored app-local exactly as today
    And it is displayed per the photo precedence
    And an honest state identifies the photo as kept on this phone
    And nothing crashes and no photo is lost

  Scenario: Save failure keeps the app-local photo, no false success (failure)
    Given a writable-looking system record and a save that fails
    When the failure occurs
    Then the system record is unchanged (no-op)
    And the picked photo remains app-local
    And no success is claimed and no failure dialog interrupts the elderly user

  Scenario: No link — today's behavior exactly
    Given a family contact with no link
    When the family member sets a photo
    Then the app-local path applies exactly as before this feature
    And no error appears anywhere
```

**Related:** FR-FCU-007/008/009 · NFR-FCU-002/005.

### FR-FCU-011: Multi-nickname storage, as entered, with no-loss migration

**Area:** Nicknames / Storage & Migration · **Priority:** MUST
**Source:** Owner request ask 3; feature constitution Nickname contract properties 1 and 7,
Feature Constraint 2; Open Decision 2 RESOLVED (store-as-entered, no auto-transliteration);
DV-6. Surface: `FamilyContactStore` (single `nickname` :71, custom decoder :122-150).

Each family contact **must** support MULTIPLE nicknames/name variations, stored explicitly **as
entered**: no automatic transliteration/romanization ("sanu" and "सानु" are distinct unless both
stored); the existing single `nickname` migrates into the multi-nickname structure without loss
and remains matchable in BOTH search and voice (DV-6); payloads from before the field existed
keep loading; whitespace-only entries are not stored; round-trips preserve entries and order as
entered; a contact with no nicknames behaves exactly as today; the stored entries are the source
of truth (any index is derived — NFR-FCU-001).

```gherkin
Feature: Multiple nicknames stored as entered

  Scenario: Multiple variations are stored as entered and survive a round-trip
    Given a family contact whose name is "सीता शर्मा"
    When the family member records the nicknames "sanu" and "सानु"
    Then both entries are stored exactly as entered, with no transliteration applied
    And both survive a save/load round-trip

  Scenario: The pre-change single nickname migrates without loss
    Given a payload carrying the old single nickname field
    When the store is read
    Then the nickname appears in the multi-nickname structure
    And it still matches in search and in voice resolution

  Scenario: A pre-field payload loads nickname-less (migration)
    Given a payload written before the nickname field existed
    When the store is read
    Then the contact loads with no nicknames
    And it behaves exactly as today

  Scenario: Whitespace-only entries are not stored (edge)
    Given the family member enters only spaces as a nickname
    When the contact is saved
    Then no nickname entry is stored
    And no query can match on an empty entry
```

**Related:** FR-FCU-012/013/015 · NFR-FCU-001/006.

### FR-FCU-012: Nickname matching in in-app search

**Area:** Nicknames / Search Matching · **Priority:** MUST
**Source:** Owner request ask 3; feature constitution Nickname contract properties 2–5 and
Feature Constraint 3; DV-5. Surfaces: `UnifiedContactSearch.familyMatches` (:217 — nickname NOT
matched today), `FamilyMatchTier` (:155), `NepaliTextNormalizer`.

`UnifiedContactSearch` **must** match a typed query against the stored name OR ANY
nickname/variation, with semantics IDENTICAL to today's family-name matching — reuse, do not
fork: `NepaliTextNormalizer` folding (NFC forms, Devanagari digits, lowercasing, punctuation);
Character-safe substring with `[.caseInsensitive, .diacriticInsensitive]`; the grapheme
behavior regression-pinned (NFR-FCU-007, no "fixes"); tier discipline — a nickname hit ranks
below an exact stored-name match and above raw containment, with the relationship tier unchanged
(exact tier insertion design-l1's to fix); linked pairs found via nickname still yield one row
(FR-FCU-003); no transliteration bridging (cross-script matches only when both spellings
stored).

```gherkin
Feature: Nickname matching in in-app search

  Scenario: The query equals a stored nickname
    Given a family contact with the nickname "sanu"
    When the user types "sanu"
    Then the contact matches

  Scenario: The query is a substring of a nickname
    Given a family contact with the nickname "सानु"
    When the user types "सान"
    Then the contact matches under the same substring semantics as name matching

  Scenario: An exact stored-name match outranks a nickname match
    Given contact A matches the query exactly by stored name
    And contact B matches the same query by nickname
    When results are ranked
    Then A ranks above B

  Scenario: Cross-script is not bridged (failure/edge)
    Given a family contact whose only nickname is "सानु"
    When the user types "sanu"
    Then the contact does not match
    And no transliteration is attempted
```

**Related:** FR-FCU-003/011/013/014 · NFR-FCU-001/004/007.

### FR-FCU-013: Nickname matching in voice call resolution

**Area:** Nicknames / Voice Resolution · **Priority:** MUST
**Source:** Owner request ask 3; feature constitution Nickname contract properties 2 and 5 and
Feature Constraint 7; DV-2. Surfaces: `ContactResolver` (anchors :41, scoring :93, accept 0.6 /
margin 0.15 :61–62), `MethodResolver` (`resolve` :47 — also edited by call-dialer; sequence per
NFR-FCU-008).

Voice call resolution **must** resolve a spoken name OR any nickname/variation (including
Devanagari forms), reusing the existing deterministic path: same normalization/scoring discipline
(`NepaliTextNormalizer` folding, honorific stripping, existing bands) — no fork; a nickname hit
is never upgraded to an exact-name match; the accept threshold (0.6) and ambiguity margin (0.15)
discipline preserved; relationship anchors unchanged; "LLM proposes, code disposes" preserved;
once resolved, `MethodResolver`'s chain (explicit → family preference → confirmed history →
global default) is unchanged; cross-script not bridged (existing honest not-found/near-miss
behavior applies).

```gherkin
Feature: Nickname matching in voice call resolution

  Scenario: "call <nickname>" reaches the right person
    Given a family contact with the nickname "sanu"
    When the user says "sanu लाई कल गर" / "call sanu"
    Then that contact is resolved and the standard confirmation names them

  Scenario: A Devanagari variation resolves
    Given a family contact with the Devanagari nickname "सानु"
    When the user says "सानुलाई फोन गर"
    Then that contact is resolved

  Scenario: A nickname is never upgraded to the exact-name band
    Given a contact whose nickname equals the spoken query
    And another contact whose stored name equals the same query
    When resolution runs
    Then the exact stored-name match outranks the nickname hit
    And the nickname is not treated as an exact-name match

  Scenario: Cross-script is not bridged (failure/edge)
    Given a contact whose only nickname is "सानु"
    When the user says "sanu"
    Then the contact is not resolved from that alone
    And the existing honest not-found/near-miss behavior applies
```

**Related:** FR-FCU-004/011/012/014 · NFR-FCU-001/007/008.

### FR-FCU-014: An ambiguous nickname never silently dials the wrong person

**Area:** Nicknames / Ambiguity Safety · **Priority:** MUST (safety-critical)
**Source:** Feature constitution Nickname property 6 (core guarantee); Safety & Compliance
Delta; DV-2. Surface: `ContactResolver` rivals rule + `.ambiguous` outcome + `nearMiss`
discipline.

When a nickname/variation matches several contacts, resolution **must** be conservative and
deterministic, mirroring `ContactResolver`'s existing rivals rule: two or more plausible matches
within the margin → ambiguous (the system asks; it never guesses); **core guarantee: resolution
must never silently dial the wrong person** — no dial until unambiguous or explicitly confirmed;
deterministic outcomes/ordering (no random tie-breaks); a nickname hit competing with an exact
name follows the bands (exact name wins); the phone-search list showing all matches is
legitimate — the guarantee binds the resolution/dial decisions; a unique nickname resolves
directly (no false disambiguation).

```gherkin
Feature: Ambiguity safety for nicknames

  Scenario: An ambiguous nickname asks instead of dialing
    Given the nickname "sanu" matches two contacts within the ambiguity margin
    When the user says "call sanu"
    Then the system reports ambiguity and asks which person
    And no call is placed until the choice is resolved
    And the finally chosen person is the one dialed

  Scenario: Exact name beats a competing nickname (no wrong dial)
    Given the spoken query exactly equals contact A's stored name
    And the same query matches contact B only by nickname
    When resolution runs
    Then contact A is resolved
    And contact B is not dialed off that utterance

  Scenario: Resolution is deterministic across runs
    Given the same contact set and the same ambiguous nickname
    When resolution is run repeatedly
    Then the outcome and candidate ordering are identical every time
    And no flaky or random selection occurs

  Scenario: A unique nickname resolves without false disambiguation
    Given a nickname recorded for exactly one contact
    When the user says that nickname
    Then that contact resolves directly
    And no unnecessary disambiguation is triggered
```

**Related:** FR-FCU-004/011/013 · NFR-FCU-005/009.

### FR-FCU-015: Family-editor nickname management UI

**Area:** Nicknames / Editor UI · **Priority:** MUST
**Source:** Owner request ask 3; workflow scope comment (editor + ne/en copy); Feature
Constraints 11 and 2; surfaces: `FamilyContactsSettingsView` (`SettingsView.swift:1529`;
nickname step :2575), `AppCoordinator` plumbing (`addFamilyContact` :6515, `updateFamilyContact`
:6566), `FamilyContactValidation`.

The family editor **must** let the family member manage multiple nicknames per contact: add,
edit, remove entries (control shape design-level); the legacy single nickname pre-populates the
new control (migration visible); saving writes through the normal store path and takes effect
immediately in search and voice (no restart); a removed entry stops matching immediately; the
management surface lives with the family contact management in Settings, localized ne/en and
accessible per house standards; save-gate rules extended only if design makes the new fields
gate Save (migrating a legacy contact and saving must never be blocked by a new rule).

```gherkin
Feature: Nickname management in the family editor

  Scenario: Add two variations and use them immediately
    Given the family member edits a contact
    When they add the nicknames "sanu" and "सानु" and save
    Then both are stored
    And both are immediately matchable in search and in voice resolution

  Scenario: Editing and removing entries takes effect immediately
    Given a contact with nicknames "sanu" and "syanu"
    When the family member removes "syanu" and saves
    Then "syanu" no longer matches in search or voice
    And "sanu" still matches

  Scenario: A legacy contact opens with its nickname pre-populated
    Given a contact saved with the old single nickname field
    When the editor opens it
    Then the old nickname appears as one nickname entry
    And saving without changes preserves it (no loss)
```

**Related:** FR-FCU-001/011/012/013 · NFR-FCU-004/005/006.

### FR-FCU-016: Feasibility honesty — the three asks reported explicitly, no silent drop

**Area:** Delivery / Feasibility Reporting · **Priority:** MUST
**Source:** Owner request 2026-10-12 ("If not feasible, tell the owner"); feature constitution
Feature Constraint 12 and Success Criteria; workflow design-l1 scope comment.

The feature's design and sign-off artifacts **must** state, explicitly and per ask (LINK, PHOTO
unification, NICKNAMES), whether each is feasible and delivered as specified: the statement is
part of the design record from design-l1 forward and of the final sign-off record (owner-visible
at the T1 story gate and the T2 sign-off); any infeasible or partially infeasible ask is named
with the ask, the constraint, the behavior actually delivered, and the pre-authorized fallback
taken — no silent drop and no claim of delivery; a partially infeasible sub-capability (e.g.
writes under limited access) is reported as a bounded behavior with its honest fallback; nothing
about the three asks may be silently omitted.

```gherkin
Feature: Feasibility honesty for the three owner asks

  Scenario: All three asks feasible — the report says so with evidence
    Given LINK, PHOTO unification and NICKNAMES are all feasible as specified
    When the design and sign-off artifacts are produced
    Then each ask is stated as delivered
    And evidence pointers (design sections, tests, DV items) are cited

  Scenario: An infeasible ask is named with its fallback (failure)
    Given one of the three asks cannot be delivered as specified on the target iOS
    When the design record and final sign-off are produced
    Then that ask is named explicitly
    And the platform constraint and the fallback actually taken are stated
    And the feature does not claim the ask delivered

  Scenario: A partially infeasible sub-capability is bounded, not dropped
    Given a sub-capability (e.g. the write under limited access) delivers only conditionally
    When the report is produced
    Then the limitation is stated as a bounded behavior with its honest fallback
    And it is neither omitted nor overstated
```

**Related:** FR-FCU-009/010/017 · NFR-FCU-009.

### FR-FCU-017: DV-* device validation recorded and passed (completion gate)

**Area:** Validation / Completion Gate · **Priority:** MUST
**Source:** Feature constitution Success Criteria & Completion Gate (DV-1 … DV-6); workflow
`final-sign-off` comment; house precedent (FR-MTC-020, SP/LCT device-validation protocols).

The feature **must not** be considered done until the DV-* checklist is executed on the
reference device (Anzaan) and recorded with the feature spec: **DV-1** — link a system contact
as a family contact → the person appears ONCE in search results (matched AND unmatched queries)
and in the call list; **DV-2** — voice: "call `<nickname>`" including a Devanagari variation
reaches the right person, and an ambiguous nickname never silently dials a wrong person;
**DV-3** — photo write: setting a photo updates the system contact when permission allows, and
the displayed photo reflects the system contact; **DV-4** — fallback: with write access
denied/limited (or a read-only system contact) the photo stays app-local, honestly surfaced, no
loss, no crash; **DV-5** — search by name and by each recorded nickname/variation (Devanagari
included) finds the single linked row; **DV-6** — migration: an existing install's pre-change
payloads load and the pre-change single nickname still matches. Each item recorded as passed/
failed with evidence attached to the feature spec; a failure blocks final sign-off until fixed
and re-run — no silent waiver. The release-build log-surface evidence accompanies the DV record
(NFR-FCU-002/009).

```gherkin
Feature: Device-validation completion gate

  Scenario: Every DV item is executed on Anzaan and recorded
    Given the implementation is complete and the scoped test gates are green
    When device validation runs
    Then DV-1 through DV-6 are each executed on the reference device
    And each result (pass/fail with evidence) is recorded with the feature spec

  Scenario: Migration is validated on a real existing install (DV-6)
    Given an existing install with pre-change payloads
    When the new build is installed over it
    Then all pre-change contacts load
    And the pre-change single nickname still matches in search and voice

  Scenario: A failed DV item blocks completion (failure)
    Given any DV item fails (e.g. the linked person still appears twice)
    When completion is assessed
    Then the feature does not pass final sign-off
    And the failure is fixed and the item re-run before sign-off proceeds
```

**Related:** FR-FCU-001..014 · NFR-FCU-006/009.

---

## Non-functional requirements

### NFR-FCU-001: Nickname index and matching performance stay within the interaction envelope

**Category:** Performance · **Priority:** MUST
**Source:** Feature constitution Nickname property 2 ("Indexed for match performance") and
Feature Constraint 7; surfaces: `UnifiedContactSearch.search` (per-keystroke; family half
`familyMatches` :217), `ContactResolver.resolve` (per-utterance).

Nickname matching **must** be indexed so matching cost is bounded and the interaction envelope
is not regressed: the index is derived from the stored entries (source of truth) and maintained
on every add/edit/remove (removed never matches; added matches immediately); measurable
envelope on the reference device (Anzaan) — with the maximum roster (12 contacts × up to 8
nicknames = 96 keys) plus address-book entries, the family half of one search query completes in
**≤ 20 ms** and voice resolution adds **≤ 20 ms**; no unbounded raw-string scans per keystroke;
index memory proportional to entry count; contacts without nicknames perform exactly as today.

```gherkin
Feature: Nickname index and match performance

  Scenario: Full-roster matching stays under the latency bounds
    Given 12 family contacts each with 8 stored nicknames
    When the family-half search runs for a query and voice resolution runs for a nickname
    Then the family-half query completes in ≤ 20 ms on the reference device
    And voice resolution adds ≤ 20 ms
    And typing/confirmation stays responsive with no perceived regression

  Scenario: The index reflects edits immediately
    Given a contact whose nickname was just added or removed
    When the next query runs
    Then the added nickname matches and the removed nickname does not
    And no stale index entry produces a false match

  Scenario: No-nickname contacts behave as today
    Given contacts with no nicknames
    When search and voice resolution run
    Then their matching cost and behavior are unchanged from today
```

**Related:** FR-FCU-011/012/013/015 · NFR-FCU-006/009.

### NFR-FCU-002: PII / log safety — names, nicknames, numbers, links and photos never reach logs

**Category:** Privacy / Security · **Priority:** MUST
**Source:** Feature constitution Safety & Compliance Delta (PII/log discipline, B2/T-050
precedent) and Feature Constraint 8; workflow `security-design-review`/`security-test` focus;
project constitution Standards and Release gates.

No raw personal data from the new paths **must** reach any log, telemetry event or diagnostic
surface beyond the existing transcript policy (B2/T-050): zero occurrences of raw contact names,
nicknames, phone numbers, system-contact identifiers/link values, photo data or address-book
contents across a Release-build exercise of the new paths (link/dedupe, photo write and
failure, fallback, nickname resolution, ambiguity, unlink, stale-link degradation);
classification-only observability (event kind, outcome, reason code — never content); errors
(`CNSaveRequest` failures, lookup failures) log reason codes, never payloads or identities;
`ios/tools/check-release-log-safety.sh` exits 0 with the new write/fallback/resolution/dedupe
source paths covered, plus the pre-release device console check; existing B1/B2 disciplines
intact across the touched files.

```gherkin
Feature: Log safety for the contacts-unify paths

  Scenario: A Release exercise of the new paths logs no content
    Given a Release build
    When link/dedupe, a photo write, the fallback, nickname resolution and an ambiguity outcome are exercised
    Then no name, nickname, number, identifier or photo data appears in the console or logs
    And only non-content classifications are emitted

  Scenario: The release log-safety gate covers the new paths and exits 0
    Given the feature's write/fallback/resolution paths exist in the build
    When ios/tools/check-release-log-safety.sh runs
    Then it exits 0
    And its coverage includes the new source paths

  Scenario: Error paths log no raw content (failure)
    Given a CNSaveRequest failure or a link-lookup failure
    When the error is handled
    Then only a reason classification is recorded
    And no contact name, number, nickname or identifier reaches the log
```

**Related:** FR-FCU-005/006/008/009/010/012/013/014 · NFR-FCU-003/007/009.

### NFR-FCU-003: No new network egress — contacts, links, nicknames and photos stay on-device

**Category:** Privacy · **Priority:** MUST
**Source:** Feature constitution Out of scope and Feature Constraint 8; Safety & Compliance
Delta; workflow non-goals; project constitution Architecture Constraint 1.

The feature **must** add no network surface and no data collection: the link reference,
nickname entries, system-contact reads and the photo write stay on-device; nothing is
transmitted anywhere; no telemetry of the new paths' content (NFR-FCU-002's classifications are
local logging discipline, not an upload); no new `Info.plist` privacy usage keys (the existing
Contacts authorization, its disclosure updated per FR-FCU-009, is the only permission touch);
measurable — the diff introduces zero new outbound hosts/APIs and a full Release-build exercise
makes zero network requests attributable to the feature, completing fully offline.

```gherkin
Feature: No new network egress

  Scenario: The feature diff adds no network surface
    Given the complete feature change set
    When it is inspected for outbound calls, endpoints and new permission keys
    Then zero new outbound hosts/APIs exist
    And no new Info.plist privacy usage keys are added

  Scenario: The flows work offline and transmit nothing
    Given a Release build with networking unavailable
    When linking, photo set/fallback, nickname search/voice match and ambiguity are exercised
    Then every flow completes on-device
    And no network request attributable to the feature is made
```

**Related:** FR-FCU-001..015 (all on-device flows), FR-FCU-009 · NFR-FCU-002/009.

### NFR-FCU-004: Localisation — every new user-visible string exists in ne and en

**Category:** Localisation · **Priority:** MUST
**Source:** Feature constitution Feature Constraint 11 and In scope; workflow scope comment;
project constitution Standards; house precedent `L10nCatalogCoverageTests`.

Every new user-visible string (link flow, photo states/fallback labels, permission copy where
user-visible, nickname management, new empty/honest states) **must** exist in both Nepali and
English in `ios/ElderlyAssistant/Resources/Localizable.xcstrings`: each new key resolves via
`L10n.str` in both shipped languages (`en-US`, `ne-NP`) to a non-key value, with the two
resolutions differing (the coverage-suite discipline — a ne copy pasted from en fails); no
missing-key fallback text user-visible; the catalog coverage suite extended with the feature's
keys and passing.

```gherkin
Feature: Localisation coverage of the new strings

  Scenario: Every new key resolves in both shipped languages
    Given the feature's new user-visible keys
    When the catalog coverage suite runs
    Then each key resolves in ne and en via L10n.str to a non-key value
    And the two resolutions differ

  Scenario: A missing or short-copied translation fails the suite (failure)
    Given a new key without a ne entry (or with an en-copied ne value)
    When the coverage suite runs
    Then it fails naming the key

  Scenario: The in-app surfaces render in the active language
    Given the active language is Nepali
    When the family editor, the photo fallback state and the nickname management render
    Then all new copy is the Nepali string
```

**Related:** FR-FCU-001/009/010/015 · NFR-FCU-005/009.

### NFR-FCU-005: Accessibility — voice-first capability, house touch standards, no authorization reasoning for the elderly user

**Category:** Accessibility · **Priority:** MUST
**Source:** Feature constitution Photo property 6 and Success Criteria (voice-first); project
constitution Standards (voice-first; ≥44×44 pt targets; 18pt body) and Target Users.

The new capabilities **must** meet the house accessibility standards: voice-first — a nickname
(Devanagari included) resolves and calls with zero touch (FR-FCU-013/014); touch standards where
touch exists — every new interactive control ≥ 44×44 pt, text through the appearance typography
tokens (Dynamic Type without clipping, no fixed-point fonts), nothing clipped at Accessibility
XXXL; no authorization reasoning asked of the elderly user — no permission explanation, dialog
or write-failure state on their surfaces (the fallback is a labeled state in the editor,
silent/neutral elsewhere; FR-FCU-010); VoiceOver — new controls labeled; photos hidden from
VoiceOver per the existing pattern where a label would add nothing; nickname entries readable
and removable via standard accessible interactions.

```gherkin
Feature: Accessibility of the new capabilities

  Scenario: A nickname call completes voice-only, with zero touch
    Given a contact with a recorded nickname
    When the user speaks the nickname and confirms by voice
    Then the call flow completes without any touch interaction

  Scenario: House touch standards hold on the new controls
    Given the family editor's new link/photo/nickname controls
    When rendered at Accessibility XXXL on the reference device
    Then every interactive control measures at least 44×44 pt
    And no label or control clips or truncates
    And text scales through the appearance typography tokens

  Scenario: No authorization reasoning is asked of the elderly user (failure-adjacent)
    Given the write falls back (denied/limited/read-only)
    When the elderly user's surfaces are displayed
    Then no authorization explanation, dialog or failure state appears
    And the photo simply shows per the display precedence
```

**Related:** FR-FCU-010/013/014/015 · NFR-FCU-004/009.

### NFR-FCU-006: Migration compatibility — legacy payloads load, nothing is lost

**Category:** Reliability · **Priority:** MUST
**Source:** Feature constitution Feature Constraint 2, Link property 5, Nickname property 7,
Success Criteria; DV-6; surface: `FamilyContactStore` custom decoder :122-150; tests
`FamilyContactStoreTests`.

Existing installs **must** keep working with zero data loss: family-contact payloads in every
historical shape (no nickname field, single nickname, no photo, pre-link, pre-address/email,
current) decode without error under the custom-decoder rule, and the store read never fails on
legacy data; the pre-change single nickname remains matchable in BOTH search and voice after
migration (DV-6); load→save→load round-trips preserve every legacy and new field; measurable —
`FamilyContactStoreTests` extended with pre-change fixtures (zero decode failures, all fields
preserved) and DV-6 executed on-device on an upgrade over an existing install.

```gherkin
Feature: Migration compatibility of the family-contact store

  Scenario: The full legacy fixture set loads with zero failures
    Given payloads from every historical shape (pre-nickname, single nickname, pre-photo, pre-link, current)
    When the store is read
    Then every contact decodes
    And zero reads fail and zero contacts are lost

  Scenario: A load-save-load round-trip preserves everything
    Given a legacy contact and a fully-populated new contact
    When each is loaded, saved and loaded again
    Then all legacy fields and all new fields are identical across the round-trip

  Scenario: The pre-change single nickname still matches (DV-6 unit pin)
    Given a contact saved with the old single nickname field
    When search and voice resolution run for that nickname
    Then both surfaces still match the contact
```

**Related:** FR-FCU-002/011/017 · NFR-FCU-001/009.

### NFR-FCU-007: Devanagari substring / grapheme-cluster behavior regression-pinned

**Category:** Reliability · **Priority:** MUST
**Source:** Feature constitution Out of scope and Feature Constraint 3, Nickname property 4;
workflow `security-test` focus ("no grapheme 'fixes'"); project memory (pin as regression, do
not "fix").

The existing Character-safe substring / grapheme-cluster behavior is **frozen**: nickname
matching reuses the exact existing semantics (`Character`-safe `range(of:options:)` with
`[.caseInsensitive, .diacriticInsensitive]`, `NepaliTextNormalizer` folding, exactly as the name
path) with no new options, no cluster normalization, no partial-word "improvements"; the pin is
test-enforced — existing expectation cases in `NepaliTextNormalizerTests`,
`UnifiedContactSearchTests`, `ContactResolverTests` stay unchanged and green, and new nickname
cases assert identical semantics; any deviation fails the suites (the pin is load-bearing).

```gherkin
Feature: The grapheme/substring behavior stays pinned

  Scenario: Existing behavior holds exactly
    Given the existing normalizer and substring-matching test cases
    When the suites run after this feature
    Then every existing expectation passes with unchanged assertions
    And no grapheme-cluster behavior was modified or "fixed"

  Scenario: Nickname matching uses the identical semantics
    Given a nickname exercising the same grapheme edge cases as a name
    When search and voice matching run over it
    Then matching behaves exactly as the name path does
    And the same compare options and folding are used (reuse, not a fork)

  Scenario: A semantic deviation fails the pin (failure)
    Given the nickname path's matching options or folding are altered
    When the pinned suites run
    Then the regression tests fail
```

**Related:** FR-FCU-012/013 · NFR-FCU-001/009.

### NFR-FCU-008: Delivery sequencing and scope separation vs call-dialer-primary-secondary

**Category:** Compliance · **Priority:** MUST
**Source:** Feature constitution Feature Constraint 1 and Sequencing Note; workflow SEQUENCING
block and Out of scope; owner instruction (this is an NFR/constraint, not a design task here).

The feature is **explicitly distinct** from `call-dialer-primary-secondary` and must not absorb
or redesign it: implementation merges master AFTER call-dialer's PR merges (queue behind it)
before implementation work starts; expected conflicts in the family-contact call surfaces
(`MethodResolver.swift`, `LeafViews.swift`, `AppCoordinator.swift`,
`CallingSettingsView.swift`) resolve as a union preserving call-dialer's shipped behavior, with
no redesign or absorption in the feature's diff; if call-dialer is unmerged, implementation
waits — no parallel edits of the conflicting surfaces; measurable — git evidence (the master
merge includes the call-dialer PR) and review evidence (the diff touches the named surfaces only
through the requirement seams, with call-dialer behavior regression-checked after the merge).

```gherkin
Feature: Sequencing and scope separation vs call-dialer

  Scenario: Implementation starts only after the dependency merged
    Given call-dialer-primary-secondary's PR exists in flight
    When implementation of this feature begins
    Then the branch has merged master including that PR (git evidence recorded)
    And no conflicting surface was edited before that merge

  Scenario: The diff does not absorb call-dialer's scope
    Given the feature's completed diff after the merge
    When it is reviewed against call-dialer's scope
    Then no call-routing/dialer redesign is present
    And the conflicting files resolve to a union preserving call-dialer's behavior

  Scenario: Unmerged dependency blocks parallel edits (failure/guard)
    Given call-dialer's PR is not yet merged
    When implementation work is about to edit the conflicting surfaces
    Then the work waits rather than forking the surface
```

**Related:** FR-FCU-004/013 · NFR-FCU-009.

### NFR-FCU-009: Test gate, release gates and baseline honesty

**Category:** Compliance · **Priority:** MUST
**Source:** Feature constitution Feature Constraint 10 and the release-gate note; workflow
`implement` overlays, `security-design-review`/`security-test` exits, `final-sign-off`; project
constitution Release gates and Quality standards.

The feature's verification is honest and gate-complete: the honest test gate is scoped/focused
XCTest suites (the full-bundle baseline carries known pre-existing failures) — at minimum
`UnifiedContactSearchTests`, `FamilyContactStoreTests`, `FamilyContactValidationTests`,
`ContactPhotoStoreTests`, `ContactResolverTests`, `MethodResolverTests`,
`MissedCallContactResolverTests`, plus the new write-seam tests and the extended
`L10nCatalogCoverageTests`; implementation runs focused tests + typecheck per unit (house rule)
with scoped runs at the gates; `ios/tools/check-release-log-safety.sh` exits 0 (build-blocking)
and the pre-release device check covers the new paths; workflow gates apply (paired review +
confidence ≥ 0.85 on implement; security-design-review and security-test exit SECURITY-GO with
STRIDE; final-sign-off at T2 + HIL); pre-existing suite failures are recorded with attribution —
never silently counted as passes or excluded; device truth lives in the DV gate (FR-FCU-017) —
no mock-only evidence substitutes.

```gherkin
Feature: Test and release gates

  Scenario: The named scoped suites pass before the review gates
    Given the implementation is complete
    When the scoped suites (contacts, storage, intents, photo, localization coverage, write-seam) run
    Then every named suite passes

  Scenario: The release log-safety gate exits 0
    Given a Release build configuration
    When ios/tools/check-release-log-safety.sh runs
    Then it exits 0 with the new paths covered

  Scenario: The known baseline stays honestly recorded
    Given the known pre-existing full-bundle failures
    When the test evidence is assembled
    Then each baseline failure is recorded with attribution
    And it is neither counted as a pass nor silently excluded
```

**Related:** FR-FCU-016/017 · NFR-FCU-002/006/007/008.

---

## Assumptions recorded during this requirements pass

Recorded so nothing is silently assumed; design-input notes, not scope changes. The full list is
in the lock file (`assumptions`).

- The integration surfaces exist as named in the feature constitution; the cited anchors were
  spot-verified against the worktree source at requirements time (`FamilyContact` struct at
  `FamilyContactStore.swift:61`, single `nickname` :71, `photoFilename` :69, custom decoder
  :122-150; `UnifiedContactSearch.dedupe` :269, `FamilyMatchTier` :155, `familyMatches` :217;
  `ContactsAccess` `AddressBookDirectory.swift:245`, `allEntries()` :386, fetch keys :333;
  `ContactResolver.relationshipAnchors` :41, scoring :93, accept 0.6 / margin 0.15 :61–62;
  `MethodResolver.resolve` :47; `ContactPhotoStore` non-throwing save/load/delete;
  `FamilyContactsSettingsView` `SettingsView.swift:1529`, nickname step :2575, `PhotosPicker`
  :2485, picked-photo load :2511; `CallView` `LeafViews.swift:918`, family rows :1747,
  `UnifiedContactResultRow` :2288, `ContactTile` avatar :2559+; `AppCoordinator.contactPhoto` 
  :6492, `addFamilyContact` :6515; `NSContactsUsageDescription` `Info.plist:115`; no
  `CNSaveRequest` exists in the app today; `Localizable.xcstrings` present;
  `L10nCatalogCoverageTests` and `check-release-log-safety.sh` present).
- Design-level choices deliberately left open (bound by invariants in the requirements): the
  link's storage shape and identifier strategy (FR-FCU-002/006); the system-contact write seam's
  file/name and injection shape (FR-FCU-008); the nickname index structure (NFR-FCU-001); unlink
  mechanics and UI (FR-FCU-005); which representation a linked row renders (FR-FCU-003); whether
  strict number-matching may establish a counterpart for an UNLINKED family contact for photo
  display (FR-FCU-007; not required by this set); removal semantics for a linked contact's photo
  (beyond the invariants of FR-FCU-008/010); whether nicknames feed `ContactResolver.nearMiss`
  (not required; the existing name-only discipline may be extended conservatively at design's
  option).
- Non-family book rows (system contacts without a family record) keep today's presentation —
  initials avatar, no photo rendering — unchanged by this feature.
- Exact user-facing copy (link flow, photo fallback labels, permission copy, nickname editor) is
  design-dependent and localization-bound; the ne/en keys must exist per NFR-FCU-004.
- The known pre-existing full-bundle test failures remain the baseline for NFR-FCU-009; the
  feature's own and touched suites must pass, with baseline failures recorded rather than
  silently included or excluded.

## Open decisions

**None open.** Both Open Decisions in the feature constitution were resolved by the parent
session on 2026-10-12 before the first run (loggable defaults under the standing
workstream-autonomy grant; recorded for the audit trail) — the design phases elaborate this
supplement, they do not re-open it:

| # | Decision | Resolution |
|---|---|---|
| OD-1 | Design path — brainstorming/frozen-design phase first, or straight to design-l1? | **RESOLVED: straight to design-l1.** The owner request is concrete with pre-authorized fallbacks; the T1 owner-story HIL (this task's gate) is the review point. |
| OD-2 | Automatic transliteration/romanization ("sanu" ↔ "सानु")? | **RESOLVED: no — store-as-entered.** Each script matches only when recorded; auto-bridging risks a wrong-person call (bound in FR-FCU-011/012/013). |

No genuine owner-level question was raised during elicitation beyond these two resolved items.

## Out of scope

Explicitly not in scope (feature constitution "Out of scope (must not change)" plus the workflow
scope comment's non-goals):

- **`call-dialer-primary-secondary`** — explicitly distinct, in flight; no absorption,
  redesign or scope merge; implementation queues behind its merge (NFR-FCU-008).
- **Bulk address-book sync/import** and editing any system-contact field other than the photo
  (no name/number writes, no bulk rewrites) — FR-FCU-008.
- **Automatic transliteration / romanization** — "sanu" and "सानु" distinct unless both stored
  (OD-2; FR-FCU-011/012/013).
- **Redesigning the call-resolution chain** — `ContactResolver`/`MethodResolver` structure beyond
  the named nickname seam is unchanged.
- **Any new network surface; any new data collection; anything leaving the device** —
  NFR-FCU-003.
- **The Devanagari substring/grapheme-cluster behavior** — regression-pinned, not "fixed"
  (NFR-FCU-007).
- **Emergency-contact semantics** — unchanged.
- **Per-contact ownership across devices; non-family book-row photo display** — book rows keep
  today's initials avatar.
- **Android** — no platform scope beyond the existing iOS app.

## Related

- Structured set: [`define-requirements/index.md`](define-requirements/index.md) ·
  [`define-requirements/FR/index.md`](define-requirements/FR/index.md) ·
  [`define-requirements/NFR/index.md`](define-requirements/NFR/index.md)
- Locked snapshot: [`define-requirements.lock.yaml`](define-requirements.lock.yaml)
- Feature constitution: [`specs/family-contacts-unify/constitution.md`](family-contacts-unify/constitution.md)
- Feature workflow (scope comment): [`specs/family-contacts-unify/workflow.yaml`](family-contacts-unify/workflow.yaml)
