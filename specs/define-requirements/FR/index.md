# Functional Requirements — Medication Schedules and Reminders

22 functional requirements. IDs are namespaced `FR-MSR-NNN` to avoid colliding with the
project-level `FR-NNN` set in the root stakeholder brief (`requirements.md`) — the same convention
live-camera-translation used (`FR-LCT-NNN`), profile-interview used (`FR-PI-NNN`),
spotify-music-integration used (`FR-SP-NNN`), multi-turn-conversation used (`FR-MTC-NNN`),
family-contacts-unify used (`FR-FCU-NNN`), call-dialer-primary-secondary used (`FR-CDP-NNN`) and
conversational-nepali-replies used (`FR-CNR-NNN`). This page covers the
`medication-schedules-reminders` set (`FR-MSR-*`) only; the earlier feature files remain in this
folder and are not part of this feature's requirements or lock.

The root brief's `FR-026` … `FR-030` and the dementia supplement's `FR-D01` … `FR-D04e` are
referenced for traceability, never renumbered. All 22 requirements are MUST — this is a
safety-critical revamp of the medication path; there is no polish tier.

| ID | Title | Area | Priority |
|----|-------|------|----------|
| [FR-MSR-001](FR-MSR-001-slot-based-entry-model.md) | Slot-based entry model — quantity + time-of-day slot + before/after meal | Entry Model | MUST |
| [FR-MSR-002](FR-MSR-002-deterministic-slot-to-clock-mapping.md) | Deterministic slot-to-clock mapping — 08:00 / 13:00 / 19:00 defaults, family-configurable | Slot-to-Clock Mapping | MUST |
| [FR-MSR-003](FR-MSR-003-structured-quantity-dose-line.md) | Structured quantity — amount + unit composed into the rendered dose line | Quantity & Dose Line | MUST |
| [FR-MSR-004](FR-MSR-004-purpose-at-entry.md) | Purpose at entry — a brief purpose description on every medication | Purpose | MUST |
| [FR-MSR-005](FR-MSR-005-scan-to-fill-additive.md) | Scan-to-fill — additive beside manual entry, bounded extraction | Scan-to-Fill | MUST |
| [FR-MSR-006](FR-MSR-006-ocr-human-confirmation-before-binding.md) | OCR values require human confirmation before binding — never silent auto-apply | Scan-to-Fill / Safety | MUST |
| [FR-MSR-007](FR-MSR-007-voice-ack-names-medication-and-slot.md) | Voice acknowledgement names the medication and slot — resolution by what was said | Voice Acknowledgement | MUST |
| [FR-MSR-008](FR-MSR-008-conservative-disambiguation-copy-rule.md) | Conservative disambiguation — "did you mean X / X or Y" copy rule, never the wrong medication | Voice Acknowledgement / Safety | MUST |
| [FR-MSR-009](FR-MSR-009-acknowledgement-safety-sequence.md) | Acknowledgement safety sequence preserved — challenge, then double-dose check, then record | Medication Safety Sequence | MUST |
| [FR-MSR-010](FR-MSR-010-intake-recorded-against-schedule.md) | Intake recorded against the day's schedule — scheduled time and acknowledged time | Recording & Adherence | MUST |
| [FR-MSR-011](FR-MSR-011-refusal-first-denial-guard.md) | Refusal-first denial guard preserved — a denial never falls through to an acknowledgement | Ack Vocabulary Guard | MUST |
| [FR-MSR-012](FR-MSR-012-mic-continuity-around-acks.md) | Mic continuity around acknowledgements — no gap between acknowledgement and listening | Voice Pipeline / Ack Fast Lane | MUST |
| [FR-MSR-013](FR-MSR-013-photo-evidence-augments-never-replaces.md) | Photo of the medication as intake evidence — augments, never replaces, never creates a record | Photo Evidence / Safety | MUST |
| [FR-MSR-014](FR-MSR-014-photo-evidence-shared-slot-resolution.md) | Photo evidence resolves the shared slot deterministically — never the wrong medication | Photo Evidence | MUST |
| [FR-MSR-015](FR-MSR-015-significant-event-notification-set.md) | Significant-event notification set — missed dose, double-dose, intake recorded, escalation started | Caregiver Notification | MUST |
| [FR-MSR-016](FR-MSR-016-caregiver-channels-honest-delivery.md) | Caregiver notification channels and honest per-contact delivery | Caregiver Notification / Delivery Honesty | MUST |
| [FR-MSR-017](FR-MSR-017-pii-free-wire.md) | PII-free wire — significant events extend the existing taxonomy with no new PII | Wire Discipline / Safety | MUST |
| [FR-MSR-018](FR-MSR-018-honest-degradation-deferred-capabilities.md) | Honest degradation — deferred capabilities surfaced as themselves, never a false success | Honesty / Delivery Integrity | MUST |
| [FR-MSR-019](FR-MSR-019-existing-reminder-escalation-preserved.md) | Existing reminder and escalation semantics preserved — no weakening of medication safety invariants | Preserved Machinery | MUST |
| [FR-MSR-020](FR-MSR-020-dementia-machinery-preserved.md) | Dementia machinery preserved and integrated — never rebuilt, never removed | Preserved Machinery | MUST |
| [FR-MSR-021](FR-MSR-021-elderly-fit-ux-new-flows.md) | Elderly-fit UX of the new flows — voice-first completion, plain language, vocabulary limit | Elderly-Fit UX | MUST |
| [FR-MSR-022](FR-MSR-022-persistence-before-alarm-and-rearm.md) | Persistence before alarm and process-kill re-arm — the FR-029 invariant holds on the revamped paths | Persistence & Recovery | MUST |

## Traceability to the source mandate

| Source | Requirements |
|--------|--------------|
| Owner scope point 1 (slot-based entry model) | FR-MSR-001, FR-MSR-002, FR-MSR-003 |
| Owner scope point 2 (purpose) | FR-MSR-004 |
| Owner scope point 3 (scan-to-fill; manual as before) | FR-MSR-005, FR-MSR-006 |
| Owner scope point 4 (voice ack with slot, recorded against the day's schedule) | FR-MSR-007 … FR-MSR-012 |
| Owner scope point 5 (photo as evidence, shared slot) | FR-MSR-013, FR-MSR-014 |
| Owner scope point 6 (caregivers always notified) | FR-MSR-015, FR-MSR-016, FR-MSR-017 |
| Owner scope point 7 (fit for forgetful elderly users) | FR-MSR-021 (+ NFR-MSR-005) |
| Safety delta (a) OCR never auto-binds | FR-MSR-006 |
| Safety delta (b) deterministic slot-to-clock mapping | FR-MSR-002 |
| Safety delta (c) photo evidence never creates a record | FR-MSR-013 |
| Safety delta (d) PII-free wire | FR-MSR-017 |
| Root FR-026 – FR-028 (delivery, escalation, missed dose) | FR-MSR-019, FR-MSR-015 |
| Root FR-029 / NFR-027 (persistence, re-fire) | FR-MSR-022 |
| Root FR-030 / supplement FR-D04 (adherence view) | FR-MSR-010 |
| Supplement FR-D01 – FR-D03 (challenge, denial, double dose) | FR-MSR-009, FR-MSR-020, FR-MSR-011 |
| Supplement FR-D04a – FR-D04e (photo verification machinery) | FR-MSR-013, FR-MSR-020 |
