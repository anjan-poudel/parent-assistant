# Requirements — Medication Schedules and Reminders

Feature: `medication-schedules-reminders` (branch `feat/medication-schedules-reminders`, worktree
`elderly-ai-assistant-medication-schedules-reminders`; scaffold base master `261aa862`).
Task: `define-requirements`, agent `ba`, contracts `requirements_doc` + `requirements_lock`.
Date: 2026-10-15. HIL gate `bedf72fc` approved by the owner from Slack (2026-10-14T22:22:30Z);
the locked snapshot in `define-requirements.lock.yaml` is the drift-detection baseline for
downstream tasks.

## Summary

- Functional requirements: **22** (`FR-MSR-001` … `FR-MSR-022`), all MUST.
- Non-functional requirements: **10** (`NFR-MSR-001` … `NFR-MSR-010`), all MUST.
- Areas covered: Entry Model; Slot-to-Clock Mapping; Quantity & Dose Line; Purpose; Scan-to-Fill;
  Voice Acknowledgement (with disambiguation and copy discipline); Medication Safety Sequence;
  Recording & Adherence; Ack Vocabulary Guard; Voice Pipeline / Ack Fast Lane; Photo Evidence;
  Caregiver Notification (significant-event set, channels, delivery honesty); Wire Discipline;
  Honesty / Delivery Integrity; Preserved Machinery; Elderly-Fit UX; Persistence & Recovery;
  Privacy (observability, on-device egress); Localisation (strings, spoken times, Devanagari pin);
  Accessibility; Reliability / Compatibility (migration); Quality / Compliance; Performance
  (firing latency).
- Source mandate: the owner's brief (seven scope points, 2026-10-15) restated in
  [`../medication-schedules-reminders/constitution.md`](../medication-schedules-reminders/constitution.md),
  which is the feature source of truth (binding contracts: Entry Model & Slot-to-Clock Mapping;
  Intake Acknowledgement & Recording; Scan-to-Fill; Photo-as-Evidence; Caregiver Notification;
  plus the Safety & Compliance Delta (a)–(d)).
- Traceability inputs (read-only, never renumbered): root `requirements.md` `FR-026` … `FR-030` and
  `NFR-027`; `requirements-dementia-supplement.md` `FR-D01` … `FR-D04e`; the shipped scheduler plan
  `docs/medication-scheduler-implementation-plan.md`.
- Settled decisions carried as requirements: slot-to-clock defaults 08:00 / 13:00 / 19:00,
  family-configurable (OD-1 → FR-MSR-002); structured quantity, amount + unit composed into the
  rendered dose line, double-dose detector semantics unchanged (OD-2 → FR-MSR-003); significant-event
  set = missed medication + possible double dose + intake recorded + escalation started, PII-free
  wire, transport scope honest (OD-3 → FR-MSR-015/016/017).

## Contents

- [FR/index.md](FR/index.md) — functional requirements (22 files, `FR-MSR-001` … `FR-MSR-022`)
- [NFR/index.md](NFR/index.md) — non-functional requirements (10 files, `NFR-MSR-001` … `NFR-MSR-010`)
- [../define-requirements.md](../define-requirements.md) — consolidated, human-readable copy of this
  set (the `requirements_doc` contract artifact)
- [../define-requirements.lock.yaml](../define-requirements.lock.yaml) — locked snapshot with
  per-requirement content hashes (the `requirements_lock` contract artifact)

Note: the `FR/` and `NFR/` folders also contain the earlier features' requirement files
(call-dialer-primary-secondary `FR-CDP-*`/`NFR-CDP-*`, conversational-nepali-replies
`FR-CNR-*`/`NFR-CNR-*`, family-contacts-unify `FR-FCU-*`/`NFR-FCU-*`, live-camera-translation
`FR-LCT-*`/`NFR-LCT-*`, multi-turn-conversation `FR-MTC-*`/`NFR-MTC-*`, profile-interview
`FR-PI-*`/`NFR-PI-*`, spotify-music-integration `FR-SP-*`/`NFR-SP-*`), left in place untouched; the
indexes on this page and the lock cover the `medication-schedules-reminders` set only.

## Open decisions

**OD-1 … OD-3 are RESOLVED** in the feature constitution (2026-10-15) and are carried by this set
as settled requirements (FR-MSR-002, FR-MSR-003, FR-MSR-015/016/017).

**OD-4 … OD-8 remain open and belong to the design chain (`design-l1` / `design-l2`).** They are
choices inside the contracts this set fixes — not scope questions — and are carried forward with
their boundaries:

| # | Decision (design-chain) | Bounded by |
|---|---|---|
| OD-4 | Scan-to-fill confirm step details, extraction surface nuances and partial-fill behaviour | FR-MSR-005 (additive, non-destructive, refuses to guess), FR-MSR-006 (human confirmation before binding is fixed) |
| OD-5 | Legacy entries in the new model — how pre-revamp entries render in the slot UI, and whether any backfill (time-to-slot inference) happens at migration | NFR-MSR-006 (no loss; legacy times readable/representable; any re-interpretation deterministic, visible, family-directed; the recorded safe default is no automatic inference) |
| OD-6 | Voice ack with slot — exact resolution mechanics and interaction order for the new utterance shapes | FR-MSR-007 (by what was said, simple acks keep working), FR-MSR-008 (conservative, deterministic, sanctioned copy), FR-MSR-009 (sequence order never bypassed) |
| OD-7 | Caregiver "calendar events" channel mechanism — existing schedule mirror vs. significant events as calendar entries vs. another shape; which events surface there | FR-MSR-016 (consent gate respected, honest results), FR-MSR-017 (no new PII on any channel) |
| OD-8 | Photo-as-evidence mechanism and recipient — reuse the existing photo-verification path once wired, an on-device-only variant, or an extension of the per-medication dementia mechanism; what the photo proves and who judges it | FR-MSR-013 (augments never replaces; never assumes the unwired machinery works; on-device; delivery discipline if it leaves the device), FR-MSR-014 (deterministic, conservative resolution), FR-MSR-020 (removal of the dementia mechanism forbidden) |

No owner-level decision is left open by this pass; the OD-1 … OD-3 resolutions above were approved
at the scaffold stage and were not reopened.

## Out of scope

- **Emergency-call and health-monitoring modules** — untouched.
- **Android** — deferred to v2; not reopened.
- **No weakening of any existing medication safety invariant** — the reminder/escalation semantics,
  persistence-before-alarm, process-kill re-arm and the LLM-independence of the medication
  scheduler unit all remain binding (FR-MSR-019, FR-MSR-022, NFR-MSR-001).
- **No removal of the existing dementia machinery** — confirmation challenge, double-dose
  detection, photo-verification components are integrated and extended, never rebuilt or removed
  (FR-MSR-020).
- **No new cloud egress for medication content** — label/photo processing stays on-device; the
  recorded cloud exceptions (voice transcription; OCR'd-text translation) do not apply to this
  feature (NFR-MSR-003).
- **No new PII on the caregiver wire** — the title-on-wire question stays an explicit owner-level
  decision (FR-MSR-017).
- **Devanagari substring/grapheme-cluster behaviour** — regression-pinned; not "fixed"
  (NFR-MSR-007).
- **Partial-vs-full dose detection** — out of scope; the double-dose detector's semantics are
  unchanged (FR-MSR-003).
