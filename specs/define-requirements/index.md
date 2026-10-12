# Requirements — Family Contacts Unify

Feature: `family-contacts-unify` (worktree branch `feat/family-contacts-unify`, worktree
`elderly-ai-assistant-family-contacts-unify`; scaffold base master `8089c735`).
Status: **submitted for owner HIL approval** (risk tier T1, per the feature workflow's
`define-requirements` task). The owner's 2026-10-12 request is settled input and both Open
Decisions were resolved before the first run (recorded below); the locked snapshot in
`define-requirements.lock.yaml` is the drift-detection baseline.
Task: `define-requirements`, agent `ba`, contracts `requirements_doc` + `requirements_lock`.
Date: 2026-10-12.

## Summary

- Functional requirements: **17** (`FR-FCU-001` … `FR-FCU-017`), all MUST (launch blocker).
- Non-functional requirements: **9** (`NFR-FCU-001` … `NFR-FCU-009`), all MUST.
- Areas covered: Link (Add Flow, Storage & Migration, Unlink, Degradation), Search / Dedupe,
  Identity / Cross-surface, Photo (Display, Write Path, Authorization, Fallback & Degradation),
  Nicknames (Storage & Migration, Search Matching, Voice Resolution, Ambiguity Safety, Editor
  UI), Delivery / Feasibility Reporting, Validation / Completion Gate. NFR categories:
  Performance, Privacy/Security, Privacy, Localisation, Accessibility, Reliability, Compliance.
- The three owner asks and their coverage:
  **LINK** — FR-FCU-001 … FR-FCU-006 (one person everywhere; link-aware dedupe beyond today's
  matched-only normalized-number rule; unlinked pairs keep today's behavior exactly);
  **PHOTO** — FR-FCU-007 … FR-FCU-010 (system photo displayed when present; app writes only the
  edited contact's photo via `CNContactStore`/`CNSaveRequest`; honest full/limited/denied
  states; the pre-authorized app-local `ContactPhotoStore` fallback with no loss, no false
  success, no crash);
  **NICKNAMES** — FR-FCU-011 … FR-FCU-015 (multiple variants stored as entered — no automatic
  transliteration; indexed; matched by name OR any variant in BOTH in-app search and voice
  resolution, reusing the existing `NepaliTextNormalizer` + Character-safe substring semantics;
  an ambiguous nickname never silently dials the wrong person).
  **Feasibility honesty** — FR-FCU-016 (each ask reported explicitly; no silent drop).
  **Completion gate** — FR-FCU-017 (DV-1 … DV-6 on the reference device Anzaan, recorded).
- Primary sources of truth: `specs/family-contacts-unify/constitution.md` (feature supplement:
  Purpose & Scope, Link Identity & Dedupe Contract, Photo Unification Contract, Nickname &
  Variation Contract, Safety & Compliance Delta, Feature Constraints 1–12, Integration
  Surfaces, Success Criteria, DV gate, Open Decisions — both RESOLVED); the owner request
  2026-10-12 as distilled in the workflow scope comment
  (`.ai-sdd/workflows/family-contacts-unify.yaml`); project `constitution.md` (inherited
  constraints, standards, release gates).
- Stakeholder brief: **there is no `requirements.md` for this feature** (the owner request
  recorded in the scaffold brief plus the constitution are the stakeholder input; none was
  created). The project-root `requirements.md` is a read-only input and is not addressed by
  this feature beyond its standing constraints.
- Completion gate: DV-1 (link → one row), DV-2 (voice incl. Devanagari nickname + ambiguity
  safety), DV-3 (photo write), DV-4 (fallback), DV-5 (search by name and each variation),
  DV-6 (migration on an existing install) — executed on Anzaan and recorded with the feature
  spec; the release-build log-surface gate covers the new write/fallback/resolution paths.

## Contents

- [FR/index.md](FR/index.md) — functional requirements (17 files, `FR-FCU-001` … `FR-FCU-017`)
- [NFR/index.md](NFR/index.md) — non-functional requirements (9 files, `NFR-FCU-001` …
  `NFR-FCU-009`)
- [../define-requirements.md](../define-requirements.md) — consolidated, human-readable copy of
  this set (the `requirements_doc` contract artifact)
- [../define-requirements.lock.yaml](../define-requirements.lock.yaml) — locked snapshot with
  per-requirement content hashes (the `requirements_lock` contract artifact)

Note: the `FR/` and `NFR/` folders also still contain the previously shipped
live-camera-translation (`FR-LCT-*`, `NFR-LCT-*`), profile-interview (`FR-PI-*`, `NFR-PI-*`),
spotify-music-integration (`FR-SP-*`, `NFR-SP-*`) and multi-turn-conversation (`FR-MTC-*`,
`NFR-MTC-*`) requirement files, left in place untouched; the indexes on this page and the lock
cover the `family-contacts-unify` set only.

## Open decisions

**None open.** Both Open Decisions carried by the feature constitution were resolved by the
parent session on 2026-10-12 before the first run (loggable defaults under the standing
workstream-autonomy grant; recorded for the audit trail) — the design phases elaborate this
supplement, they do not re-open it:

| # | Decision | Resolution |
|---|---|---|
| OD-1 | **Design path** — brainstorming/frozen-design phase first, or straight to design-l1? | **RESOLVED: proceed straight to design-l1.** The owner request is concrete with pre-authorized feasibility fallbacks, and the T1 owner-story HIL (this task's gate) is the review point a brainstorming phase would otherwise provide. |
| OD-2 | **Automatic transliteration/romanization** — bridge scripts ("sanu" ↔ "सानु") automatically? | **RESOLVED: no — store-as-entered.** Romanized and Devanagari forms each match only when recorded explicitly; multiple nicknames let the owner record both scripts as two entries. Auto-bridging risks a wrong-person call, which is worse than a missed match (bound in FR-FCU-011/FR-FCU-012/FR-FCU-013). |

Design-level choices deliberately left to design-l1/l2 and the security-design-review (not owner
decisions): link storage shape, write-seam shape, index structure, unlink mechanics, and which
representation a linked row renders. The requirements bind the behavioural invariants around
each.

## Out of scope

Explicitly not in scope (feature constitution "Out of scope (must not change)" plus the workflow
scope comment's explicit non-goals) — recorded so nothing is silently half-built:

- **`call-dialer-primary-secondary`** — explicitly distinct, in flight; this feature must not
  absorb, redesign or merge its scope. Implementation queues behind its merge (NFR-FCU-008).
- **Bulk address-book sync/import**, and editing any system-contact field other than the photo
  (no name/number writes, no bulk rewrites) — FR-FCU-008.
- **Automatic transliteration / romanization** — "sanu" and "सानु" are distinct spellings unless
  both are stored (OD-2; FR-FCU-011/012/013).
- **Redesigning the call-resolution chain** — `ContactResolver`/`MethodResolver` structure beyond
  the named nickname seam is unchanged.
- **Any new network surface; any new data collection; anything leaving the device** — NFR-FCU-003.
- **The Devanagari substring/grapheme-cluster behavior** — regression-pinned; must not be
  "fixed" (NFR-FCU-007).
- **Emergency-contact semantics** — unchanged by this feature.
- **Per-contact ownership across devices**, and non-family book-row photo display — the owner
  ask and the constitution bind family contacts; book rows keep today's initials avatar
  (recorded as an assumption in the lock).
- **Android** — no platform scope beyond the existing iOS app.

## Verification and gates

- Honest test gate: scoped/focused XCTest suites (`UnifiedContactSearchTests`,
  `FamilyContactStoreTests`, `FamilyContactValidationTests`, `ContactPhotoStoreTests`,
  `ContactResolverTests`, `MethodResolverTests`, `MissedCallContactResolverTests`, the new
  write-seam tests, the extended `L10nCatalogCoverageTests`) — NFR-FCU-009.
- Release gate: `ios/tools/check-release-log-safety.sh` exits 0, covering the new
  write/fallback/resolution paths — NFR-FCU-002.
- Workflow gates: `security-design-review` + `security-test` (SECURITY-GO; STRIDE covers the new
  write surface and identity/link semantics), paired review + confidence 0.85 on implement,
  `final-sign-off` at T2 + HIL — NFR-FCU-009; the DV-* record rides the final sign-off
  (FR-FCU-017).

## Related

- Consolidated copy: [`../define-requirements.md`](../define-requirements.md)
- Locked snapshot: [`../define-requirements.lock.yaml`](../define-requirements.lock.yaml)
- Feature constitution: [`../family-contacts-unify/constitution.md`](../family-contacts-unify/constitution.md)
- Feature workflow (scope comment): [`../family-contacts-unify/workflow.yaml`](../family-contacts-unify/workflow.yaml)
- Owner request 2026-10-12: recorded in the feature constitution (Source of truth) and the workflow scope comment.
