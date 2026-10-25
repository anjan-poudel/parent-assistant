# Implementation Tasks — Reminders Instructions Enhancements

Flat unit layout. Every file in this directory except this index is one implementation unit discovered by the ai-sdd unit engine. There are no group subdirectories and no subtask files.

The previous feature plan that occupied this directory is preserved byte-for-byte under `specs/plan-tasks/archive/pre-reminders-instructions-enhancements-2026-10-25/` so unit discovery yields only this feature's units.

## Units

| ID | Title | Group | Wave | Effort | Depends on | Risk |
|----|-------|-------|------|--------|------------|------|
| [T-001](T-001.md) | Instruction model, configuration, filename guard and inspection seam | TG-01 | 0 | M (2) | — | HIGH |
| [T-002](T-002.md) | Instruction video store — create-before-bytes, protection and sweeps | TG-02 | 1 | L (3) | T-001 | CRITICAL |
| [T-003](T-003.md) | Instruction draft algebra and collapsed display state | TG-01 | 2 | M (1.5) | T-002 | HIGH |
| [T-004](T-004.md) | Playback seam and AVKit adapter | TG-03 | 1 | M (1.5) | T-001 | HIGH |
| [T-005](T-005.md) | Instruction image loaders and filename guard reuse | TG-01 | 1 | S (1) | T-001 | HIGH |
| [T-006](T-006.md) | Camera and microphone permission seam | TG-01 | 1 | S (1) | T-001 | HIGH |
| [T-007](T-007.md) | Typed observability and the plain-copy map | TG-01 | 3 | M (1.5) | T-002, T-003, T-004, T-005, T-006 | HIGH |
| [T-008](T-008.md) | Video importer — validate, bound and discard | TG-02 | 2 | M (1.5) | T-002 | HIGH |
| [T-009](T-009.md) | Capture coordinator — single flight, camera first, honest states | TG-02 | 4 | L (2) | T-002, T-006, T-007, T-008 | CRITICAL |
| [T-010](T-010.md) | Platform capture adapters — permission-free picker and capped recorder | TG-02 | 5 | M (1.5) | T-009 | HIGH |
| [T-011](T-011.md) | Routine entry instruction delta and the strict store read | TG-04 | 1 | M (1.5) | T-001 | CRITICAL |
| [T-012](T-012.md) | Routine notification content builder and had_instruction payload | TG-04 | 0 | S (1) | — | HIGH |
| [T-013](T-013.md) | Routine scheduler write seam, ordered transaction and entry teardown | TG-04 | 4 | L (2.5) | T-002, T-007, T-011, T-012 | CRITICAL |
| [T-014](T-014.md) | Event extras instruction field, snapshot and mutation repair | TG-04 | 1 | M (1.5) | T-001 | HIGH |
| [T-015](T-015.md) | Free-form event service and form instruction seam | TG-04 | 5 | L (2) | T-002, T-007, T-013, T-014 | CRITICAL |
| [T-016](T-016.md) | Fire handlers — instruction-aware presentation and three tap cases | TG-05 | 6 | M (1.5) | T-011, T-012, T-015 | HIGH |
| [T-017](T-017.md) | Playback controller — preflight bound, ready watchdog and late-event safety | TG-03 | 4 | M (1.5) | T-004, T-007 | HIGH |
| [T-018](T-018.md) | Instruction card, cover and editor views | TG-06 | 6 | L (2.5) | T-003, T-005, T-007, T-009, T-010, T-017 | HIGH |
| [T-019](T-019.md) | Instruction copy catalogue — 36 keys in English and Nepali | TG-01 | 0 | S (1) | — | MEDIUM |
| [T-020](T-020.md) | Camera and microphone usage disclosure and built-bundle registration | TG-01 | 1 | S (1) | T-019 | HIGH |
| [T-021](T-021.md) | Fired-screen overlay — D6 time gate and deleted-owner notice | TG-05 | 7 | M (1.5) | T-018 | CRITICAL |
| [T-022](T-022.md) | Coordinator service seams and production factories | TG-06 | 6 | M (1.5) | T-002, T-008, T-010, T-013, T-015, T-017 | HIGH |
| [T-023](T-023.md) | Routine settings instruction editor integration | TG-06 | 7 | S (1) | T-018, T-022 | HIGH |
| [T-024](T-024.md) | Events view instruction editing and detail surface | TG-06 | 7 | S (1) | T-015, T-018, T-022 | MEDIUM |
| [T-025](T-025.md) | Coordinator fired-screen composition, tap routing and launch sweep | TG-06 | 8 | M (1.5) | T-011, T-014, T-016, T-021, T-022 | HIGH |
| [T-026](T-026.md) | Release-log gate registration and source-hygiene suite | TG-07 | 8 | S (1) | T-010, T-018, T-021 | HIGH |
| [T-027](T-027.md) | Feature integration, release gates and the single full-suite run | TG-07 | 9 | M (2) | T-001 through T-026 | CRITICAL |

## Totals

- Units: 27 (26 implementation units plus one closing integration unit, `final: true`)
- Waves: 0–9 (ten waves)
- Nominal effort: 42 developer-days
- Critical path: T-001 → T-002 → T-003 → T-007 → T-009 → T-010 → T-018 → T-021 → T-025 → T-027 (about 19 sequential-equivalent days)

## Group labels

Group labels are navigation aids only. Waves are computed from `depends_on` and `files`, not from group membership.

- TG-01 — Model, copy and foundations: T-001, T-003, T-005, T-006, T-007, T-019, T-020
- TG-02 — Video bytes, import and capture: T-002, T-008, T-009, T-010
- TG-03 — Playback: T-004, T-017
- TG-04 — Routine and event owner seams: T-011, T-012, T-013, T-014, T-015
- TG-05 — Notification handling and fired screen: T-016, T-021
- TG-06 — Surfaces and composition: T-018, T-022, T-023, T-024, T-025
- TG-07 — Gates and release: T-026, T-027
