# Constitution — family-contacts-unify (feature supplement)

Applies to the `family-contacts-unify` workflow only (`.ai-sdd/workflows/family-contacts-unify.yaml`, the load path; canonical `specs/family-contacts-unify/workflow.yaml` — the pair is kept byte-identical, per the workflow header). The project constitution (`/constitution.md`) is inherited unchanged — Architecture Constraints 1–6, Standards, release gates, and Agent Principles all bind this feature. This supplement does not restate project-level rules; it records only what the feature adds, what it must not change, and the decisions left open.

Source of truth: no frozen design doc exists for this feature (unlike `call-dialer-primary-secondary`). The owner request recorded in the scaffold brief (2026-10-12) is the source; `design-l1`/`design-l2` are the first design pass — echoed in Open Decisions. If the owner wants a brainstorming/frozen design first, that is a parent-level decision (Open Decision 1).

## Feature Purpose & Scope

Purpose: family contacts and system (Apple Contacts) entries are duplicated in the app. The owner asks for three things, each with a pre-authorized feasibility fallback ("if not feasible, tell the owner"):

1. **LINK** — search a system contact and add/link it as a family contact, so the two records are ONE person and never two rows anywhere in the app.
2. **PHOTO unification** — setting a picture in the app also updates the system contact's photo; photos from system contacts are displayed when present; when the system contact is not writable (permission denied / limited access / read-only), the photo stays app-local exactly as today — no silent loss.
3. **NICKNAMES** — multiple nicknames / name variations per family contact (e.g. sanu, syanu, Devanagari forms), indexed, matching by name OR any nickname/variation in BOTH in-app search and voice call resolution.

Primary user: the elderly parent (voice-first; Nepali/Devanagari), with the owner (family member) managing contacts on their behalf. Success is observable: searching the parent's name or ANY recorded nickname — typed or spoken — finds ONE entry and calls the right person; the person never appears twice; the displayed photo reflects the system contact, and a photo set in the app reaches the system contact when permitted.

In scope:

- A stored LINK between a family contact and a system contact, honored by every surface that renders or resolves people (search, call list, voice resolution, missed-call correlation).
- Link-aware dedupe in the unified search/list beyond today's matched-only normalized-number rule; unlinked pairs keep today's behavior exactly.
- The app's FIRST write into the system address book: `CNContactStore`/`CNSaveRequest` confined to the edited contact's photo; authorization states (full / limited / denied) handled honestly; system-contact photos displayed when present.
- The app-local fallback unchanged: `ContactPhotoStore` `photoFilename` remains the photo path when the system contact is not writable — no silent loss, no false success.
- Multiple nicknames/name variations per family contact, stored explicitly, indexed, matched in search and voice through the existing matching semantics.
- Model migration per the house rule: optional fields, custom-decoder defaults; pre-existing payloads load and the existing single nickname migrates without loss.
- ne/en strings in `Localizable.xcstrings`; scoped XCTest suites as the test gate.

Out of scope (must not change):

- `call-dialer-primary-secondary` — explicitly distinct, in flight; do not absorb, redesign, or merge its scope.
- Bulk address-book sync/import, and editing any system-contact field other than the photo (no name/number writes, no bulk rewrites).
- Automatic transliteration/romanization — "sanu" and "सानु" are distinct spellings unless both are stored.
- Redesigning the call-resolution chain (the `ContactResolver`/`MethodResolver` structure beyond the named nickname seam).
- Any new network surface; any new data collection; anything leaving the device.
- The Devanagari substring/grapheme-cluster behavior (regression-pinned — do not "fix" it).
- Emergency-contact semantics.

## Link Identity & Dedupe Contract

Binding properties (design-l1 decides the shape; these must hold):

1. A linked (family ↔ system) pair is ONE person everywhere: unified search results, the call list's family rows, voice call resolution, and missed-call correlation — never two rows, for any query.
2. Dedupe becomes link-aware beyond today's matched-only normalized-number rule (`UnifiedContactSearch.dedupe`): an explicit link is identity evidence independent of number spelling. A query matching EITHER side of a linked pair yields exactly one row for that person, and the person stays findable by whatever matched.
3. Unlinked pairs keep today's behavior EXACTLY: unmatched family twins must not hide book twins (the current `UnifiedContactSearch` contract). The link widens dedupe only through explicit linkage — number-only matches do not become more aggressive.
4. Linking must never make a person unreachable: a stale or broken link (system record deleted, re-synced, identifier lookup failure) degrades to today's behavior — never hides the person, never crashes, never strands a call.
5. The link is stored on the family contact under the house migration rule (optional fields, custom-decoder defaults) — a pre-link payload loads unlinked.

## Photo Unification Contract

Binding properties:

1. Write path: the app may write ONLY the edited contact's photo, via `CNContactStore`/`CNSaveRequest` — one contact at a time, no bulk rewrites, no other fields. This is the app's first write surface into the shared address book; the blast radius is confined to that one contact's photo.
2. Authorization: full / limited / denied (and read-only records) are all honest states. Permission is requested at the point of use with plain-language explanation; a non-writable contact is detected, not assumed.
3. Display precedence: the system contact's photo when present, else the app-local `photoFilename` thumbnail, else the existing initials avatar.
4. Fallback: when the system contact is not writable — permission denied, limited access, or a read-only record — the picked photo stays app-local exactly as today (`ContactPhotoStore`), with honest UI state. Never crash; never lose the picked photo; never claim an unverified write succeeded.
5. The system record must never be corrupted or silently mangled; a failed write is a no-op on the system side, never a partial mutation.
6. Best-effort by construction, consistent with the existing photo stack: photo operations never surface a throw or a failure dialog; a failed write is a labeled state, and the elderly user is never asked to reason about address-book authorization.

## Nickname & Variation Contract

Binding properties:

1. Multiple nicknames/name variations per family contact (e.g. sanu, syanu, Devanagari forms), stored explicitly as entered — no automatic transliteration: "sanu" and "सानु" are distinct spellings unless both are stored.
2. Indexed for match performance, and matched by the stored name OR any nickname/variation in BOTH in-app search (`UnifiedContactSearch` union) and voice call resolution (`ContactResolver`/`MethodResolver` seams).
3. Matching semantics are IDENTICAL to today's family-name matching: `NepaliTextNormalizer` folding; `[.caseInsensitive, .diacriticInsensitive]` Character-safe substring; relationship anchors on `ContactResolver.relationshipAnchors`. Reuse, do not fork.
4. The grapheme-cluster / Devanagari substring behavior is regression-pinned: the existing Character-safe substring behavior must hold exactly; do not "fix" it.
5. Match order mirrors the `UnifiedContactSearch.FamilyMatchTier` discipline: the exact stored name remains the strongest signal; a nickname/variation hit ranks below an exact name and above raw containment; the relationship tier's existing behavior is unchanged. In voice resolution, nickname hits follow the same conservative scoring discipline as the name path and are never upgraded to an exact-name match.
6. Ambiguity is conservative and deterministic: a nickname matching several contacts resolves like `ContactResolver`'s existing rivals rule — the system disambiguates; it never guesses. Core guarantee: resolution must never silently dial the wrong person.
7. Migration: the existing single `nickname` migrates into the multi-nickname structure without loss; pre-field payloads keep loading (custom-decoder defaults); a contact with no nicknames behaves exactly as today.

## Safety & Compliance Delta

No new compliance category — the feature stays within the project's safety-critical baseline (vulnerable elderly user, PII, emergency semantics). What is NEW and review-worthy:

- **Write authority:** the app's first write surface into the shared system address book (`CNContactStore`/`CNSaveRequest` — today a read-only sweep; no `CNSaveRequest` exists in the app). Confined to the edited contact's photo; a wrong-contact write or a corrupting write must be prevented by construction, not merely detected.
- **Voice-resolution correctness:** nickname matching feeds call resolution — a wrong or ambiguous match dials the wrong person. Index and match semantics must be deterministic and conservatively ordered; ambiguity refuses to dial.
- **Identity integrity:** a link is identity evidence — a wrong link merges two different people. Link/unlink semantics and stale-link degradation are security-design-review material.
- **Degradation safety:** permission denied/limited or a failed save falls back to the app-local photo with honest UI — no loss, no false success, no crash.
- **PII / log discipline:** names, numbers and photos must not reach logs beyond existing policy (B2/T-050 is the binding precedent); the release-build log-surface gate must cover the new write/fallback/resolution paths.
- **No new egress:** nothing leaves the device; no new network surface.

Gates: the workflow file carries the project-baseline gates — `security-design-review` (STRIDE required; SECURITY-GO exit), `security-test` (SECURITY-GO exit), paired review + confidence 0.85 on implement, `final-sign-off` at T2 + HIL. This section is the feature risk delta those gates review against; the workflow file is the authority for gate mechanics.

## Feature Constraints

1. **Explicitly distinct from `call-dialer-primary-secondary`; sequencing.** Do not absorb or redesign it. Implementation merges master AFTER its PR merges (queue behind it), expecting conflicts in `MethodResolver.swift` / `LeafViews.swift` family-contact call surfaces (see Sequencing Note).
2. **Migration rule.** New model fields optional with custom-decoder defaults; pre-existing payloads (single nickname, `photoFilename`) must keep loading; the existing single nickname migrates into the multi-nickname structure without loss.
3. **Matching semantics reused; grapheme behavior pinned.** Nickname matching MUST reuse existing name-matching semantics (`NepaliTextNormalizer` folding + `[.caseInsensitive, .diacriticInsensitive]` Character-safe substring; relationship anchors on `ContactResolver`'s table). The Devanagari substring / grapheme-cluster behavior is regression-pinned — do not "fix" it.
4. **Photo write is best-effort with the pre-authorized fallback.** Permission denied / limited access / read-only contact degrades to the app-local photo (`ContactPhotoStore` `photoFilename`) — never crash, never lose the picked photo, never claim an unverified success.
5. **`CNSaveRequest` only, photo only.** Writes are limited to the edited contact's photo; no bulk rewrites; no editing other fields of system contacts.
6. **One person, one row.** A linked pair is one person everywhere (search, call list, voice resolution); dedupe becomes link-aware beyond today's matched-only normalized-number rule; unlinked pairs keep today's matched-only behavior.
7. **Nicknames indexed and matched in both surfaces.** Multiple nicknames are indexed for match performance and match in BOTH search and voice resolution (`ContactResolver`/`MethodResolver` seams).
8. **No new network surface; no new data collection; PII discipline.** Names, numbers and photos must not reach logs beyond existing policy (B2/T-050).
9. **Delivery — house rule (inherited).** Work ONLY in the sibling worktree `/Users/anjan/workspace/projects/elderly-ai-assistant-family-contacts-unify` (branch `feat/family-contacts-unify`); integrate via PR against master; never the main checkout.
10. **Test gate.** Scoped/focused XCTest suites are the honest gate (the full-bundle baseline has pre-existing failures): `UnifiedContactSearchTests`, `FamilyContactStoreTests`, `ContactResolverTests`, `MethodResolverTests`, `ContactPhotoStoreTests`, `MissedCallContactResolverTests`.
11. **Localization.** All new user-visible strings ne/en in `ios/ElderlyAssistant/Resources/Localizable.xcstrings`.
12. **Feasibility honesty.** If any of the three asks proves infeasible on iOS (e.g. the write-permission model), the deliverable states it explicitly for the owner — no silent drop (the owner asked to be told).

## Integration Surfaces (verified in this worktree)

Verified against this worktree at master 8089c735 (branch `feat/family-contacts-unify`); line numbers are orientation, not contracts.

| Surface | Change | Verified detail |
|---|---|---|
| `ios/ElderlyAssistant/Services/Storage/FamilyContactStore.swift` | `FamilyContact` grows: multi-nickname structure + link reference; custom decoder migrates legacy payloads | struct at :61; single `nickname` :71; `photoFilename` :69; custom decoder :122–150; unversioned store — "an optional field IS its migration" |
| `ios/ElderlyAssistant/Services/Storage/FamilyContactValidation.swift` | Save-gate rules extended if new fields gate Save (today: email rule only) | pure function `issue(email:isEmergencyContact:)` :48 |
| `ios/ElderlyAssistant/Services/Storage/ContactPhotoStore.swift` | The app-local fallback path (behavior kept; photo stays app-local when the system contact is not writable) | `save`/`load(named:)`/`delete(named:)`; ≤512px JPEG under Application Support/ContactPhotos; non-throwing by design |
| `ios/ElderlyAssistant/Services/Contacts/UnifiedContactSearch.swift` | Link-aware dedupe + nickname matching in the family+book union | matched-only dedupe `dedupe(matchedFamily:in:)` :269; `FamilyMatchTier` :155; `familyMatches` :217 (name/relationship/containment; nickname NOT matched today) |
| `ios/ElderlyAssistant/Services/Contacts/AddressBookDirectory.swift` | Read path keeps its shape; the `CNContactStore` WRITE (`CNSaveRequest`) is new — here or in a new seam | read-only sweep `allEntries()` :386; fetch keys :333; `ContactsAccess` :245; no `CNSaveRequest` exists in the app today |
| `ios/ElderlyAssistant/Services/Contacts/MissedCallContactResolver.swift` | Number→person correlation must respect links so dial-back renders one person | family-first, then book; permission-gated (`ContactsAccess`); pure number matcher |
| `ios/ElderlyAssistant/Services/Intents/ContactResolver.swift` | Nickname/variation matching in voice resolution; conservative ambiguity preserved | relationship anchors :41; scoring :93; accept 0.6 / ambiguity margin 0.15 :61–62; `nearMiss` discipline |
| `ios/ElderlyAssistant/Services/Intents/MethodResolver.swift` | Nickname matching extends the contact-resolution seams feeding the method chain | chain: explicit → family preference → confirmed history → global default `.phone`; `resolve(contactId:requestedApp:callType:)` :47 (also edited by call-dialer — sequence) |
| `ios/ElderlyAssistant/App/SettingsView.swift` | Family editor: multi-nickname management + photo setter write path / fallback state | `FamilyContactsSettingsView` :1529; editor; nickname step :2575; `PhotosPicker` :2485; picked-photo load :2511 |
| `ios/ElderlyAssistant/App/LeafViews.swift` | Call list + search rows render the linked pair as one; photo display precedence (system photo when present) | `CallView` :918 (struct lives in this file — no separate `CallView.swift`); family rows :1747; `UnifiedContactResultRow` :2288; family call-card avatar/photo :2559–2648 |
| `ios/ElderlyAssistant/App/AppCoordinator.swift` | Coordinator seams: photo resolution for display, family-contact add/update/remove plumbing | `familyContacts` :937; `contactPhoto(for:)` :6492; `addFamilyContact` :6515; `updateFamilyContact` :6566; `removeFamilyContact` :6633 |
| `ios/ElderlyAssistant/Info.plist` | `NSContactsUsageDescription` :115 — current copy is read/search-oriented; write disclosure must be honest when the write surface ships | present today |
| `ios/ElderlyAssistant/Resources/Localizable.xcstrings` | New ne/en strings | present today |
| **NEW** system-contact write seam (file/name decided by design-l1) | Injectable `CNContactStore`/`CNSaveRequest` wrapper; house pattern — thin platform glue, pure logic testable | no `CNSaveRequest` exists in the app today |
| Tests: `ios/ElderlyAssistantTests/Services/Contacts/UnifiedContactSearchTests.swift`, `Services/Contacts/MissedCallContactResolverTests.swift`, `Services/Storage/FamilyContactStoreTests.swift`, `Services/Storage/FamilyContactValidationTests.swift`, `Services/Storage/ContactPhotoStoreTests.swift`, `Services/Intents/ContactResolverTests.swift`, `Services/Intents/MethodResolverTests.swift` | Scoped suites extended with the new contracts | all present today |

## Success Criteria & Completion Gate

Success:

- Searching the parent's name or ANY recorded nickname/variation — typed or spoken — finds ONE entry and calls the right person; the person never appears twice anywhere (search results, call list, voice resolution).
- The displayed photo reflects the system contact when one is present; setting a photo in the app updates the system contact when permitted.
- When the system contact is not writable (permission denied / limited / read-only), the photo stays app-local exactly as today, honestly surfaced — no loss, no crash.
- Multiple variations (sanu, syanu, Devanagari forms) are recordable and each resolves in search and voice.
- Existing installs keep loading; the pre-change single nickname still matches (migration without loss).
- Any infeasible ask is stated explicitly for the owner — no silent drop.

Completion gate — DV-* device validation on the reference device (Anzaan), recorded with the feature spec (house pattern):

- DV-1 — Link: link a system contact as a family contact → the person appears ONCE in search results (matched AND unmatched queries) and in the call list.
- DV-2 — Voice: "call `<nickname>`", including a Devanagari variation, reaches the right person; an ambiguous nickname never silently dials a wrong person (disambiguation, not a guess).
- DV-3 — Photo write: setting a photo in the app updates the system contact when permission allows; the photo displayed in the app reflects the system contact.
- DV-4 — Fallback: with write access denied/limited (or a read-only system contact), the photo stays app-local as today, honestly surfaced — no loss, no crash.
- DV-5 — Search: querying by name and by each recorded nickname/variation (Devanagari included) finds the single linked row.
- DV-6 — Migration: an existing install's pre-change payloads load; the pre-change single nickname still matches.

The project release gates apply to the new paths: the release-build log-surface gate must cover the write/fallback/resolution paths (evidence in `final-sign-off`).

## Open Decisions — RESOLVED (parent session, 2026-10-12, before first run)

Both resolved as loggable defaults under the standing workstream-autonomy grant; recorded for the audit trail. The design phases elaborate this supplement, they do not re-open it:

1. **Design path — RESOLVED: proceed straight to design-l1.** No brainstorming/frozen-design phase. Rationale: the owner request is concrete with pre-authorized feasibility fallbacks, and the T1 owner-story HIL gives the owner the review point a brainstorming phase would otherwise provide. (The `call-dialer-primary-secondary` frozen-design pattern applied there because it reshaped a shipped call-routing flow; this feature is additive.)
2. **No automatic transliteration — RESOLVED: store-as-entered.** Romanized and Devanagari forms each match only when recorded explicitly ("sanu" ≠ "सानु" unless both are stored); the feature does not transliterate, romanize, or fuzzy-bridge scripts. Rationale: matches the brief ("in devnagari"); multiple nicknames let the owner record both scripts as two entries; Nepali romanization is ambiguous (sanu/saanu/syanu/shyanu) and auto-bridging scripts risks a wrong-person call, which is worse than a missed match. Cross-script fuzzy matching remains a future feature request, not a silent behavior change.

Nothing else is left open. The three feasibility fallbacks are pre-authorized by the owner in the request itself; photo display precedence (system when present, else app-local), the app-local fallback path, migration-without-loss, and the frozen grapheme behavior are settled inputs. The remaining choices — link storage shape, write-seam shape, index structure, unlink semantics, and which representation a linked row renders — are design-level, resolved by design-l1/design-l2 and the security-design-review, not owner decisions.

## Sequencing Note (owner constraint)

`call-dialer-primary-secondary` (branch `feat/call-dialer-primary-secondary`) is in flight and unmerged; it touches the same Contacts surface (`MethodResolver.swift`, `LeafViews.swift`, `AppCoordinator.swift`, `CallingSettingsView.swift`). This feature is explicitly distinct and must not absorb or redesign it. Implementation merges master AFTER call-dialer's PR merges (queue behind it) before implementation starts; expected conflicts in `MethodResolver.swift` / `LeafViews.swift` family-contact call surfaces. Scaffold base for this worktree: master 8089c735.
