# Feature: Family Contacts Unify

**Shipped:** 2026-10-12 · **PR:** [#172](https://github.com/anjan-poudel/parent-assistant/pull/172) · **Merge commit:** `270280b9` · **Branch:** `feat/family-contacts-unify`

## What it does

Family contacts (curated in the app) and system Contacts.app entries were
duplicated in the app. This feature makes them ONE person:

1. **LINK** — search a system contact in the family editor and add it as a
   family contact. The stored link carries the system record's identifier
   plus a number fingerprint; a background verification pass keeps a
   published snapshot of verified links. A stale or moved identifier degrades
   to unlinked — it can never merge two different people. Linked pairs
   render as one row everywhere: unified search (matched AND unmatched
   queries), the call list, missed-call names, and voice resolution.
2. **PHOTO unification** — setting a contact's picture in the app also
   updates the system contact's photo (the app's first `CNSaveRequest`
   write), confined to the edited contact's photo field only, with
   read-back byte verification so a false success is impossible. When the
   system record is not writable (permission denied, limited access,
   read-only, save failure) the photo stays app-local exactly as before —
   no loss, no false success, no crash. Display precedence: system photo →
   app-local photo → initials.
3. **NICKNAMES** — multiple nicknames / name variations per family contact
   (e.g. sanu, सानु), stored exactly as entered (no automatic
   transliteration), indexed, and matched by name OR any nickname in both
   in-app search and voice call resolution. An ambiguous nickname asks
   instead of guessing — resolution never silently dials the wrong person.
   The Devanagari substring/grapheme behavior is regression-pinned.

## Architecture (one line each)

| Piece | Where | Note |
|---|---|---|
| `SystemContactLink` + `nicknames: [String]` | `Services/Storage/FamilyContactStore.swift` | unversioned-store migration via the optional-field decoder pattern |
| `FamilyContactIndex` | `Services/Contacts/FamilyContactIndex.swift` | derived value-type index, rebuilt wholesale on roster publish |
| `SystemContactLinkService` | `Services/Contacts/SystemContactLinkService.swift` | actor; batched verification, single-flight drain, photo cache |
| `SystemContactPhotoWriter` | `Services/Contacts/SystemContactPhotoWriter.swift` | actor; the ONLY file permitted to build `CNSaveRequest` |
| Dedupe passes 1–5 | `Services/Contacts/UnifiedContactSearch.swift` | link-aware pass; unlinked pairs keep today's behavior exactly |
| Voice bands | `Services/Intents/ContactResolver.swift` | +0.85 exact-nickname, +0.75 nickname containment; accept 0.6 / margin 0.15 unchanged |
| Link-aware missed calls | `Services/Contacts/MissedCallContactResolver.swift` | own phone → linked record numbers → native (with identifier remap) |
| Coordinator seams | `App/AppCoordinator.swift` | `familyContacts.didSet` choke point; generation-guarded snapshot publish; unlink; faces |
| Wizard / list / CallView | `App/SettingsView.swift`, `App/LeafViews.swift` | link section, steering, photo states, nickname list editor, chip + captions |

## Gate evidence

- review-l2 GO (3 rounds — `.limited` search-surface gates, refresh-coalescing
  input capture, L10n pin arithmetic reworked)
- security-design-review **SECURITY-GO** (STRIDE; advisories F1–F8 folded into
  the task specs)
- implement 22/22 units; review-implementation **GO 0.93** (full-diff)
- security-test **SECURITY-GO** (F1–F8 closure verified against source)
- acceptance: 32/32 scoped suites green; full bundle 7,030/7,062 with all 22
  failures attributed pre-existing at baseline; release log-safety gate exit 0
- perf: index ≤1.6 ms, voice resolution ≤10.3 ms, unified search 2.78 ms
  (ceilings 20 ms)
- feasibility honesty (FR-FCU-016): all three asks delivered as specified —
  `specs/FCU-feasibility-honesty-report.md`

## Outstanding (tracking gate)

**DV-1..6 device validation on Anzaan** — protocol and record at
`specs/FCU-device-validation-protocol.md`; every item is recorded BLOCKED
pending a device session. Per FR-FCU-017 this gates the next release build.
Also outstanding: the pre-release device console check (NFR-FCU-002 device
half).

## Spec trail

`specs/family-contacts-unify/constitution.md`, `specs/define-requirements.md`
(+ lock), `specs/design-l1.md`, `specs/design-l2.md` (rev 3),
`specs/review-l2.md`, `specs/security-design-review.md`,
`specs/plan-tasks/` (+ amendments), `specs/implement-notes.md`,
`specs/review-implementation.md`, `specs/security-test.md`,
`specs/final-sign-off.md`.
