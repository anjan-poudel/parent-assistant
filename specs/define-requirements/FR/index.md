# Functional Requirements — Family Contacts Unify (v1)

17 functional requirements. IDs are namespaced `FR-FCU-NNN` to avoid colliding with the
project-level `FR-NNN` set in the root stakeholder brief (`requirements.md`) — the same convention
live-camera-translation used (`FR-LCT-NNN`), profile-interview used (`FR-PI-NNN`),
spotify-music-integration used (`FR-SP-NNN`) and multi-turn-conversation used (`FR-MTC-NNN`).
This page covers the `family-contacts-unify` set (`FR-FCU-*`) only; the earlier feature files
remain in this folder and are not part of this feature's requirements or lock.

| ID | Title | Area | Priority |
|----|-------|------|----------|
| [FR-FCU-001](FR-FCU-001-link-system-contact-as-family.md) | Link a system contact as a family contact (the LINK flow) | Link / Add Flow | MUST |
| [FR-FCU-002](FR-FCU-002-link-reference-storage-and-migration.md) | Link reference storage with legacy-safe migration | Link / Storage & Migration | MUST |
| [FR-FCU-003](FR-FCU-003-link-aware-dedupe-unified-search.md) | Link-aware dedupe — one row for a linked person in unified search | Search / Dedupe | MUST |
| [FR-FCU-004](FR-FCU-004-one-person-every-surface.md) | One person across every people surface — call list, voice resolution, missed-call correlation | Identity / Cross-surface | MUST |
| [FR-FCU-005](FR-FCU-005-unlink-both-records-intact.md) | Unlink — reversible, with both records intact | Link / Unlink | MUST |
| [FR-FCU-006](FR-FCU-006-stale-link-degradation.md) | Stale or broken link degradation — never hide, never crash, never strand a call | Link / Degradation | MUST |
| [FR-FCU-007](FR-FCU-007-photo-display-precedence.md) | Photo display precedence — system photo, then app-local, then initials | Photo / Display | MUST |
| [FR-FCU-008](FR-FCU-008-photo-write-confined-to-edited-contact.md) | Photo write confined to the edited contact's photo | Photo / Write Path | MUST |
| [FR-FCU-009](FR-FCU-009-write-authorization-honest-states.md) | Write authorization — full, limited and denied are all honest states, detected not assumed | Photo / Authorization | MUST |
| [FR-FCU-010](FR-FCU-010-non-writable-photo-fallback.md) | Non-writable fallback — no loss, no false success, no crash | Photo / Fallback & Degradation | MUST |
| [FR-FCU-011](FR-FCU-011-multi-nickname-storage-and-migration.md) | Multi-nickname storage, as entered, with no-loss migration | Nicknames / Storage & Migration | MUST |
| [FR-FCU-012](FR-FCU-012-nickname-matching-in-search.md) | Nickname matching in in-app search | Nicknames / Search Matching | MUST |
| [FR-FCU-013](FR-FCU-013-nickname-matching-in-voice-resolution.md) | Nickname matching in voice call resolution | Nicknames / Voice Resolution | MUST |
| [FR-FCU-014](FR-FCU-014-ambiguous-nickname-never-wrong-person.md) | An ambiguous nickname never silently dials the wrong person | Nicknames / Ambiguity Safety | MUST |
| [FR-FCU-015](FR-FCU-015-nickname-management-editor-ui.md) | Family-editor nickname management UI | Nicknames / Editor UI | MUST |
| [FR-FCU-016](FR-FCU-016-feasibility-honesty-reporting.md) | Feasibility honesty — the three asks reported explicitly, no silent drop | Delivery / Feasibility Reporting | MUST |
| [FR-FCU-017](FR-FCU-017-device-validation-completion-gate.md) | DV-* device validation recorded and passed (completion gate) | Validation / Completion Gate | MUST |

## Relationship to the three owner asks

| Owner ask (2026-10-12) | Requirements |
|---|---|
| 1 — LINK: search a system contact and add it as a family contact; one person, never two rows anywhere | FR-FCU-001, FR-FCU-002, FR-FCU-003, FR-FCU-004, FR-FCU-005, FR-FCU-006 |
| 2 — PHOTO: setting a picture updates the system contact; system photos displayed; app-local fallback when the system record is not writable | FR-FCU-007, FR-FCU-008, FR-FCU-009, FR-FCU-010 |
| 3 — NICKNAMES: multiple variants per contact, indexed, matched by name OR any variant in search AND voice | FR-FCU-011, FR-FCU-012, FR-FCU-013, FR-FCU-014, FR-FCU-015 |
| Feasibility honesty ("if not feasible, tell the owner") | FR-FCU-016 |
| Completion gate (DV-1..DV-6) | FR-FCU-017 |
