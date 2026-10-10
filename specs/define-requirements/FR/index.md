# Functional Requirements — Multi-Turn Conversation (v1)

20 functional requirements. IDs are namespaced `FR-MTC-NNN` to avoid colliding with the
project-level `FR-NNN` set in the root stakeholder brief (`requirements.md`) — the same
convention live-camera-translation used (`FR-LCT-NNN`), profile-interview used (`FR-PI-NNN`) and
spotify-music-integration used (`FR-SP-NNN`). This page covers the
`multi-turn-conversation` set (`FR-MTC-*`) only; the earlier feature files remain in this folder
and are not part of this feature's requirements or lock.

| ID | Title | Area | Priority |
|----|-------|------|----------|
| [FR-MTC-001](FR-MTC-001-dialogue-frame-lifecycle.md) | Dialogue frame lifecycle and one-deep state | Dialogue Frame / Core | MUST |
| [FR-MTC-002](FR-MTC-002-degenerate-music-query-detection.md) | Degenerate music-query detection before playback | Music Path / Probe Trigger | MUST |
| [FR-MTC-003](FR-MTC-003-slot-fill-probe.md) | `.slotFill` probe — a short kind-of-request question with options and a default | Probes / Slot-Fill | MUST |
| [FR-MTC-004](FR-MTC-004-candidate-choice-did-you-mean-probe.md) | `.candidateChoice` (didYouMean) probe — honest not-understood line plus narrowing candidates | Probes / Did-You-Mean | MUST |
| [FR-MTC-005](FR-MTC-005-voice-answer-capture.md) | Voice answer capture — name, index word, repetition, free-form | Answer Capture | MUST |
| [FR-MTC-006](FR-MTC-006-deterministic-frame-merge-and-execution.md) | Deterministic frame merge and execution | Answer Merge / Execution | MUST |
| [FR-MTC-007](FR-MTC-007-probe-budget-two-then-defaults.md) | Probe budget — bounded probes, then execute with defaults | Probe Policy | MUST |
| [FR-MTC-008](FR-MTC-008-say-it-again-escape.md) | "No — let me say it again" escape re-arms a fresh capture | Answer Capture / Escape | MUST |
| [FR-MTC-009](FR-MTC-009-pre-ladder-answer-interception.md) | Pre-ladder answer interception | Interception / Routing | MUST |
| [FR-MTC-010](FR-MTC-010-cancel-drops-the-frame.md) | Cancel words drop the frame with an honest line | Interception / Cancel | MUST |
| [FR-MTC-011](FR-MTC-011-emergency-precedence-mid-frame.md) | Emergency precedence is absolute mid-frame | Safety / Emergency | MUST |
| [FR-MTC-012](FR-MTC-012-barge-in-strong-new-command.md) | Barge-in — a strong new command drops the frame | Interception / Barge-in | MUST |
| [FR-MTC-013](FR-MTC-013-timeout-silent-rearm.md) | 45 s timeout — silent drop and re-arm | Timeout / Recovery | MUST |
| [FR-MTC-014](FR-MTC-014-awaiting-slot-answer-state.md) | `awaitingSlotAnswer` session state with the 45 s timer reuse | Session State | MUST |
| [FR-MTC-015](FR-MTC-015-curated-on-device-catalog.md) | Curated on-device option catalog | Option Catalog | MUST |
| [FR-MTC-016](FR-MTC-016-template-generated-probes.md) | Template-generated probes, localized ne/en — never model-generated | Probe Generation / Localisation | MUST |
| [FR-MTC-017](FR-MTC-017-transcript-cache-bypass.md) | Transcript-cache bypass during answer capture | Cache Discipline | MUST |
| [FR-MTC-018](FR-MTC-018-follow-up-nlu-fine-tune-v17.md) | Phase 2 — follow-up NLU fine-tune v17 with the frame clause | NLU Training (Phase 2) | SHOULD |
| [FR-MTC-019](FR-MTC-019-reminder-calendar-frame-rollover.md) | Phase 3 — reminder/calendar missing-slot re-prompts on the frame path | Rollout (Phase 3) | SHOULD |
| [FR-MTC-020](FR-MTC-020-device-validation-completion-gate.md) | DV-* device validation recorded and passed (completion gate) | Validation / Completion Gate | MUST |

## Phases and priority semantics

The feature preserves the feasibility study's phase structure (study §7; workflow "PHASE
STRUCTURE"):

- **Phase 0 (prerequisite)** — PR #156 voice-OOM hardening code is merged (`437631e`,
  2026-10-10); its outstanding Anzaan device smoke (conversation → no jetsam → JetsamEvent pull)
  is the Phase 0 gate, bound by FR-MTC-020.
- **Phase 1 (deterministic MVP — shippable alone)** — FR-MTC-001 … FR-MTC-017: frame mechanics,
  both probe kinds, the curated catalog, the deterministic merge and every recovery rule. The
  owner's bhajan example must work end-to-end with no training run. All Phase 1 FRs are **MUST**.
- **Phase 2 (later phase)** — FR-MTC-018: the follow-up NLU fine-tune v17 with the frame clause;
  the clause ships ONLY with the training iteration (prompt-identity drift hazard). **SHOULD**:
  per the study's recommendation and open decision OD-M3 (sequencing — OPEN), Phase 1 ships
  first; if the owner sequences Phase 2 into the same release, FR-MTC-018 escalates to MUST.
- **Phase 3 (later phase)** — FR-MTC-019: reminder/calendar rollover and the DV-* closure;
  **SHOULD** pending open decision OD-M4 (scope — OPEN). FR-MTC-020 (the DV-* completion gate)
  is **MUST** regardless of OD-M3/OD-M4: it validates the Phase 1 behaviours.
- **Phase guard**: reminder/calendar turns are unchanged in Phase 1 (FR-MTC-019's Phase 1 guard
  scenario; NFR-MTC-012).

## Areas

Dialogue Frame / Core (1), Music Path / Probe Trigger (1), Probes / Slot-Fill (1), Probes /
Did-You-Mean (1), Answer Capture (1), Answer Capture / Escape (1), Answer Merge / Execution (1),
Probe Policy (1), Interception / Routing (1), Interception / Cancel (1), Interception / Barge-in
(1), Safety / Emergency (1), Timeout / Recovery (1), Session State (1), Option Catalog (1), Probe
Generation / Localisation (1), Cache Discipline (1), NLU Training (Phase 2) (1), Rollout (Phase
3) (1), Validation / Completion Gate (1).

## Traceability anchors

Every requirement traces to the feature constitution (`specs/multi-turn-conversation/
constitution.md` — Feature Purpose & Scope, Probe Kinds & Answer-Capture Contract, Safety-Relevant
Constraints 1–4, Feature Constraints 1–10, Integration Surfaces, Success Criteria, the DV-*
completion gate, Open Decisions OD-M1..M4), the owner's feasibility study
(`docs/multi-turn-conversation-feasibility.md` — §5 measured constraints, §6 recommended design,
§7 phasing, §8 risks, §9 open decisions) and/or the `define-requirements` scope comment in
`specs/multi-turn-conversation/workflow.yaml`. Nothing is derived from outside those sources.

## Related

- [NFR index](../NFR/index.md) — 12 non-functional requirements
- [Requirements index](../index.md)
- [Consolidated copy](../../define-requirements.md)
- [Feature constitution](../../multi-turn-conversation/constitution.md)
