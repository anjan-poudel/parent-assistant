# Requirements — Conversational Nepali Replies

Feature: `conversational-nepali-replies` (branch `feat/conversational-nepali-replies`, worktree
`elderly-ai-assistant-conversational-nepali-replies`; scaffold base master `91deddca`).
Status: **HIL gate RESOLVED** (risk tier T1). The owner approved the source proposal on
2026-10-14 ("please implement this as ai-sdd feature spec"), so the `define-requirements`
owner-story HIL is resolved by that approval rather than re-asked at this step; the T2 human gate
sits at `final-sign-off`. The locked snapshot in `define-requirements.lock.yaml` is the
drift-detection baseline.
Task: `define-requirements`, agent `ba`, contracts `requirements_doc` + `requirements_lock`.
Date: 2026-10-14.

## Summary

- Functional requirements: **29** (`FR-CNR-001` … `FR-CNR-029`) — 25 MUST (P0/P1 and the
  guardrails), 1 SHOULD (FR-CNR-026), 3 COULD (FR-CNR-027/028/029, P2 polish).
- Non-functional requirements: **11** (`NFR-CNR-001` … `NFR-CNR-011`), all MUST.
- Areas covered: Style Spec / Single Source, Persona (local + cloud seams), Decode (chat sampling
  and the command determinism invariant), Grammar Guard (verification, degradation, telemetry),
  Cloud Chat (routing, consent & disclosure, egress scope, sampling config, hygiene), Single-Decode
  Integrity, Preserved Behaviours (safety path; STT / permissions / data collection), Training
  (v17 suite extension, corpus construction, provenance), Evaluation (held-out set, chat gates,
  full regression harness, ship gate), Model Delivery (catalog swap, tiers), Prompt Discipline,
  Feasibility Reporting, Completion Gate, and the P2 polish set. NFR categories: Reliability /
  Determinism, Performance, Resource Behaviour, Privacy / Security, Privacy, Quality / Evaluation
  Gates, Accessibility, Localisation, Compliance.
- Phasing: **P0** (runtime, no training) — FR-CNR-001 … FR-CNR-012 (plus the shared guardrails
  FR-CNR-013/014/015/023/024/025); **P1** — FR-CNR-016 … FR-CNR-022; **P2** (after P1) —
  FR-CNR-026 … FR-CNR-029.
- Primary sources of truth: the owner-approved proposal
  `docs/features/2026-10-14-conversational-nepali-replies-proposal.md` (source mandate);
  `specs/conversational-nepali-replies/constitution.md` (feature supplement: purpose & scope,
  style-spec contract, runtime contract, model & training contract, provenance, safety & compliance
  delta, success criteria & DV gate, Open Decisions 1–5); `specs/conversational-nepali-replies/workflow.yaml`
  (scope comment, security focus, phasing); project `constitution.md` (inherited constraints,
  standards, release gates); `specs/conversational-nepali-replies/init-report.md` (integration
  surfaces).
- Stakeholder brief: the project-root `requirements.md` is a read-only input and is not modified
  by this feature; the feature's stakeholder input is the owner-approved proposal above.
- Completion gate: **DV-1 … DV-6** on the reference device (Anzaan), recorded at final sign-off —
  local chat quality, cloud-first consent/indicator/toggle-off, offline honest degradation,
  emergency phrasing recall on device, command determinism, elderly listening-panel A/B verdict
  (FR-CNR-025) — plus the release gate `ios/tools/check-release-log-safety.sh` exiting 0 over the
  new chat/routing/guard paths (NFR-CNR-006).

## Contents

- [FR/index.md](FR/index.md) — functional requirements (29 files, `FR-CNR-001` … `FR-CNR-029`)
- [NFR/index.md](NFR/index.md) — non-functional requirements (11 files, `NFR-CNR-001` … `NFR-CNR-011`)
- [../define-requirements.md](../define-requirements.md) — consolidated, human-readable copy of
  this set (the `requirements_doc` contract artifact)
- [../define-requirements.lock.yaml](../define-requirements.lock.yaml) — locked snapshot with
  per-requirement content hashes (the `requirements_lock` contract artifact)

Note: the `FR/` and `NFR/` folders also still contain the earlier features' requirement files
(call-dialer-primary-secondary `FR-CDP-*`/`NFR-CDP-*`, family-contacts-unify `FR-FCU-*`/`NFR-FCU-*`,
live-camera-translation `FR-LCT-*`/`NFR-LCT-*`, multi-turn-conversation `FR-MTC-*`/`NFR-MTC-*`,
profile-interview `FR-PI-*`/`NFR-PI-*`, spotify-music-integration `FR-SP-*`/`NFR-SP-*`), left in
place untouched; the indexes on this page and the lock cover the `conversational-nepali-replies`
set only.

## Open decisions

No **owner-level** decision is open. Five design-level Open Decisions are carried by the feature
constitution and are **deliberately left to `design-l1`/`design-l2`** (they are design choices
inside the contracts this set fixes, not scope questions):

| # | Open Decision | Bounded by |
|---|---|---|
| OD-1 | Chat temperature value + sampling plumbing (per-turn override vs. a shape-specific handle) and the GBNF interplay | FR-CNR-003, FR-CNR-004, NFR-CNR-001; feasibility honesty in FR-CNR-024 |
| OD-2 | Style-spec artifact format (prose vs. machine-readable) and how the four consumers resolve against it, incl. which parts the guard/eval execute directly | FR-CNR-001 (single source, no forks), NFR-CNR-005 |
| OD-3 | P0 landing path — full P0→P1→P2 in this run (owner directive) vs. P0 as a normal PR first; only ordering changes | FR-CNR-024 (a sequencing deviation is reported) |
| OD-4 | Particles-budget enforcement mechanics (which particle set counts; guard check vs. eval rubric vs. both; interaction with the ≤2-sentence ceiling and code-switched sentences) | FR-CNR-001 (the ≤1 budget is fixed), FR-CNR-005, FR-CNR-020 |
| OD-5 | The Gemini chat temperature value (the on-device side is ~0.3; the cloud value is proposed at design) | FR-CNR-011 (explicit + reviewed), FR-CNR-002 (no drift with the local contract) |

One owner-facing question is recorded rather than resolved: **OD-3** (P0 PR-first ordering), which
the proposal explicitly permits and the workflow records as an owner question — it changes
sequencing only, not scope or contracts.

## Out of scope

Explicitly not in scope (feature constitution "Out of scope (must not change)", the workflow's
scope comment non-goals, and the proposal's boundaries) — recorded so nothing is silently
half-built:

- **The single-decode schema** — one JSON (`intent` + response/reply + `confidence`); no
  chain/router surgery; v17 is a catalog swap (FR-CNR-013, FR-CNR-022).
- **Router ladder and emergency gate behaviour** — unchanged; the chat pre-check semantics beyond
  wiring the routing toggle are untouched (FR-CNR-014).
- **STT behaviour** — the speech pipeline is not part of this feature; the STT-engine invariant
  stands (FR-CNR-015).
- **Command-turn decode determinism** — temp-0 + fixed seed + GBNF `commandJSONSchema` are the
  NO-GIBBERISH invariants and stay untouched (FR-CNR-004).
- **Any new device permission** and **any new data collection** beyond the recorded cloud-chat
  egress and classification-only telemetry (FR-CNR-015, FR-CNR-010, NFR-CNR-007).
- **Few-shot exemplars in the on-device prompt** — style travels via data, not prompt tokens
  (FR-CNR-023, NFR-CNR-004).
- **The intent prompt bytes** — `IntentPrompt.build`, `seeds/prompt_template.txt` and the
  `IntentPromptTests` pin stay byte-identical (FR-CNR-023).
- **Emergency-call logic, medication flow, health monitoring and device permissions** — unchanged
  (FR-CNR-014, FR-CNR-015).
- **CC BY-NC and research-gated data in shipped artifacts** — IndicDialogue, DailyDialog,
  PersonaChat, EmpatheticDialogues and the unlicensed Nepali call-center corpus remain dev-mix only
  (FR-CNR-018).
- **Cloud routing for anything but chat** — commands, emergency phrasing and other non-chat content
  do not travel through the new toggle (FR-CNR-010).
- **Android** — no platform scope beyond the existing iOS app.

## Verification and gates

- **Workflow gates**: `review-l2` GO, `security-design-review` SECURITY-GO (STRIDE required),
  `review-implementation` GO, `security-test` SECURITY-GO, paired review + 0.85 confidence on
  implement, `final-sign-off` at T2 + HIL (NFR-CNR-011).
- **Gate harness (the ship gate)**: new chat gates — honorific agreement ≥0.98, no-AI-ism ≥0.98,
  LLM-judge mean ≥4/5 over `eval/chat_golden.jsonl` — plus the non-negotiable regressions —
  emergency recall 1.00, abstention ≥0.90, closed-intent ≥0.95, calibration ±0.10, latency
  p50 ≤1.0 s (FR-CNR-020, FR-CNR-021, NFR-CNR-008).
- **Release gate**: `ios/tools/check-release-log-safety.sh` exits 0, covering the new
  chat/routing/guard paths (no conversation content or key material in logs) (FR-CNR-012,
  NFR-CNR-006).
- **Device gate**: DV-1 … DV-6 on Anzaan, recorded at final sign-off (FR-CNR-025).

## Related

- Consolidated copy: [`../define-requirements.md`](../define-requirements.md)
- Locked snapshot: [`../define-requirements.lock.yaml`](../define-requirements.lock.yaml)
- Feature constitution: [`../conversational-nepali-replies/constitution.md`](../conversational-nepali-replies/constitution.md)
- Feature workflow (scope comment): [`../conversational-nepali-replies/workflow.yaml`](../conversational-nepali-replies/workflow.yaml)
- Owner-approved proposal: [`../../docs/features/2026-10-14-conversational-nepali-replies-proposal.md`](../../docs/features/2026-10-14-conversational-nepali-replies-proposal.md)
- Scaffold report: [`../conversational-nepali-replies/init-report.md`](../conversational-nepali-replies/init-report.md)
