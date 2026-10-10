# Requirements — Multi-Turn Conversation

Feature: `multi-turn-conversation` (worktree branch `feat/multi-turn-conversation`, worktree
`elderly-ai-assistant-multi-turn-conversation`).
Status: **submitted for owner HIL approval** (risk tier T1, per the feature workflow's
`define-requirements` task); no owner amendment is recorded at lock time — the locked snapshot in
`define-requirements.lock.yaml` is the drift-detection baseline.
Task: `define-requirements`, agent `ba`, contract `requirements_doc` + `requirements_lock`.
Date: 2026-10-10.

## Summary

- Functional requirements: **20** (`FR-MTC-001` … `FR-MTC-020`)
- Non-functional requirements: **12** (`NFR-MTC-001` … `NFR-MTC-012`)
- Areas covered: Dialogue Frame / Core, Music Path / Probe Trigger, Probes (slot-fill,
  did-you-mean), Answer Capture (forms, escape), Answer Merge / Execution, Probe Policy,
  Interception / Routing (pre-ladder, cancel, barge-in), Safety / Emergency, Timeout / Recovery,
  Session State, Option Catalog, Probe Generation / Localisation, Cache Discipline, NLU Training
  (Phase 2), Rollout (Phase 3), Validation / Completion Gate. NFR categories: Performance,
  Reliability, Privacy, Security, Localisation, Accessibility, Compliance.
- Phase structure (preserved from the study §7 and the workflow "PHASE STRUCTURE"):
  **Phase 0** = PR #156 voice-OOM hardening merged (`437631e`, 2026-10-10) with its Anzaan device
  smoke outstanding (the prerequisite gate, bound by FR-MTC-020); **Phase 1** = the deterministic
  MVP, shippable alone (FR-MTC-001 … FR-MTC-017, all MUST) — the owner's bhajan example must work
  end-to-end with no training run; **Phase 2** = the follow-up NLU fine-tune v17 with the frame
  clause, shipping ONLY with the training iteration (FR-MTC-018, SHOULD pending OD-M3);
  **Phase 3** = reminder/calendar rollover (FR-MTC-019, SHOULD pending OD-M4) plus the DV-*
  device-validation closure (FR-MTC-020, MUST).
- v1 scope: give the single-turn voice pipeline a one-deep dialogue frame (`DialogueManager` +
  `DialogueFrame`, FR-MTC-001) with two first-class probe kinds — `.slotFill` for a missing slot
  such as the bhajan deity (FR-MTC-002/003) and `.candidateChoice`/didYouMean for a
  not-understood utterance (FR-MTC-004) — voice answer capture by name, index word, repetition or
  free-form (FR-MTC-005), the deterministic merge that executes through the normal music path
  (FR-MTC-006), the bounded probe budget with default execution (FR-MTC-007), the say-it-again
  escape (FR-MTC-008), pre-ladder interception (FR-MTC-009) with cancel, emergency, barge-in and
  45 s timeout rules (FR-MTC-010 … FR-MTC-013), the `awaitingSlotAnswer` state (FR-MTC-014), the
  curated on-device catalog (FR-MTC-015), template-only probes (FR-MTC-016), the transcript-cache
  bypass (FR-MTC-017), and the Phase 2/3 follow-ups (FR-MTC-018/019) closing with the DV-* gate
  (FR-MTC-020).
- Primary sources of truth: `specs/multi-turn-conversation/constitution.md` (feature constitution
  — Purpose & Scope, Probe Kinds & Answer-Capture Contract, Safety-Relevant Constraints 1–4,
  Feature Constraints 1–10, Integration Surfaces, Success Criteria, DV-* completion gate, Open
  Decisions OD-M1..M4); `specs/multi-turn-conversation/workflow.yaml` (the `define-requirements`
  scope comment and phase structure); `docs/multi-turn-conversation-feasibility.md` (the owner's
  study — §5 measured constraints, §6 recommended design, §7 phasing, §8 risks, §9 open
  decisions); project `constitution.md` (inherited constraints, release gates).
- Read-only stakeholder briefs: `requirements.md` — a read-only input; it does not address
  multi-turn dialogue. Its FR-008 "conversational response generation" clause is **not** delivered
  or superseded by this feature (open-ended chat stays explicitly out of scope per the owner's
  2026-10-10 study and the feature constitution); its §4 Post-MVP "Music and bhajan playback"
  line (~675-676) was already superseded by the shipped spotify-music-integration feature, which
  this feature extends rather than re-opens.

## Contents

- [FR/index.md](FR/index.md) — functional requirements (20 files, `FR-MTC-001` … `FR-MTC-020`)
- [NFR/index.md](NFR/index.md) — non-functional requirements (12 files, `NFR-MTC-001` …
  `NFR-MTC-012`)
- [../define-requirements.md](../define-requirements.md) — consolidated, human-readable copy of
  this set (the `requirements_doc` contract artifact)
- [../define-requirements.lock.yaml](../define-requirements.lock.yaml) — locked snapshot with
  per-requirement content hashes (the `requirements_lock` contract artifact)

Note: the `FR/` and `NFR/` folders also still contain the previously shipped
live-camera-translation (`FR-LCT-*`, `NFR-LCT-*`), profile-interview (`FR-PI-*`, `NFR-PI-*`) and
spotify-music-integration (`FR-SP-*`, `NFR-SP-*`) requirement files, left in place untouched; the
indexes on this page and the lock cover the `multi-turn-conversation` set only.

### Functional requirements

Frame and probes: [FR-MTC-001](FR/FR-MTC-001-dialogue-frame-lifecycle.md),
[FR-MTC-002](FR/FR-MTC-002-degenerate-music-query-detection.md),
[FR-MTC-003](FR/FR-MTC-003-slot-fill-probe.md),
[FR-MTC-004](FR/FR-MTC-004-candidate-choice-did-you-mean-probe.md) ·
Answer capture and merge: [FR-MTC-005](FR/FR-MTC-005-voice-answer-capture.md),
[FR-MTC-006](FR/FR-MTC-006-deterministic-frame-merge-and-execution.md),
[FR-MTC-007](FR/FR-MTC-007-probe-budget-two-then-defaults.md),
[FR-MTC-008](FR/FR-MTC-008-say-it-again-escape.md) ·
Interception and recovery: [FR-MTC-009](FR/FR-MTC-009-pre-ladder-answer-interception.md),
[FR-MTC-010](FR/FR-MTC-010-cancel-drops-the-frame.md),
[FR-MTC-011](FR/FR-MTC-011-emergency-precedence-mid-frame.md),
[FR-MTC-012](FR/FR-MTC-012-barge-in-strong-new-command.md),
[FR-MTC-013](FR/FR-MTC-013-timeout-silent-rearm.md) ·
State, catalog and generation: [FR-MTC-014](FR/FR-MTC-014-awaiting-slot-answer-state.md),
[FR-MTC-015](FR/FR-MTC-015-curated-on-device-catalog.md),
[FR-MTC-016](FR/FR-MTC-016-template-generated-probes.md),
[FR-MTC-017](FR/FR-MTC-017-transcript-cache-bypass.md) ·
Later phases and gate: [FR-MTC-018](FR/FR-MTC-018-follow-up-nlu-fine-tune-v17.md),
[FR-MTC-019](FR/FR-MTC-019-reminder-calendar-frame-rollover.md),
[FR-MTC-020](FR/FR-MTC-020-device-validation-completion-gate.md)

### Non-functional requirements

[NFR-MTC-001](NFR/NFR-MTC-001-probe-turn-latency.md) latency envelope ·
[NFR-MTC-002](NFR/NFR-MTC-002-prompt-budget-and-token-ceiling.md) prompt budget ·
[NFR-MTC-003](NFR/NFR-MTC-003-no-new-network-egress.md) no new egress ·
[NFR-MTC-004](NFR/NFR-MTC-004-log-safety.md) log safety ·
[NFR-MTC-005](NFR/NFR-MTC-005-degraded-brain-deterministic-path.md) degraded-brain path ·
[NFR-MTC-006](NFR/NFR-MTC-006-localisation.md) localisation ·
[NFR-MTC-007](NFR/NFR-MTC-007-sustained-multi-turn-stability.md) sustained stability ·
[NFR-MTC-008](NFR/NFR-MTC-008-answer-sanitisation-and-injection-safety.md) answer-path security ·
[NFR-MTC-009](NFR/NFR-MTC-009-voice-only-accessibility.md) voice-only accessibility ·
[NFR-MTC-010](NFR/NFR-MTC-010-frame-trap-resistance.md) trap resistance ·
[NFR-MTC-011](NFR/NFR-MTC-011-kv-prefix-stability.md) KV-prefix stability ·
[NFR-MTC-012](NFR/NFR-MTC-012-compliance-and-release-gates.md) compliance gates

## Open decisions

Carried from the feature constitution (feasibility study §9) verbatim in substance; **not
resolved here**. None blocks the requirement set; each has an owner-visible resolution point.
Full text in the consolidated doc's Open decisions section.

| # | Decision | Status in this requirement set | Resolve at |
|---|---|---|---|
| OD-M1 | **Probe policy** — 1 probe vs up-to-2 before executing with defaults, and the default-play wording ('जे पनि बजाऊ'). Study recommendation: 2 probes max, default offered on the first probe | Open — owner. The requirements bind a bounded budget, the always-present default and default execution on exhaustion (FR-MTC-007, FR-MTC-003); the exact cap (1 vs 2) and copy stay open | owner (recorded in design-l1) |
| OD-M2 | **Probe option source** — curated on-device catalog (recommended for MVP: zero latency, on-device stance) vs live Spotify playlist search (richer; needs a `SpotifyTool` extension + network per probe) | Open — owner. The requirements bind the curated on-device catalog for Phase 1 (FR-MTC-015) and no new egress (NFR-MTC-003); a later live-search enrichment resolves here | owner + design-l1 |
| OD-M3 | **Sequencing** — ship Phase 1 deterministic-only first vs run Phase 2 + v17 in parallel. Study recommendation: Phase 1 first (it covers the bhajan example), v17 data authoring in parallel | Open — owner. The requirements mark Phase 2 as SHOULD pending this resolution (FR-MTC-018); Phase 1 is complete and shippable alone | owner |
| OD-M4 | **Scope** — whether Phase 3's reminder/calendar answer-capture rides the same release as the music probe | Open — owner. The requirements keep reminder/calendar unchanged in Phase 1 (FR-MTC-019 Phase 1 guard; NFR-MTC-012) and carry the Phase 3 target as SHOULD | owner |

### Assumptions recorded during this requirements pass

Recorded so nothing is silently assumed; all are design-input notes, not scope changes. The full
list is in the lock file (`assumptions`).

- The integration surfaces exist as named in the feature constitution; the cited anchors were
  spot-verified against the worktree source at requirements time (`CommandRouter.route` at 740,
  the confirmation hook at 785-886, the keyword-ladder music arm at 1223-1234,
  `routeKeywordRemainder` at 1968-2030, `selectMusicOutcome`/`fireMusicRequest`/`runMusicTurn` at
  2614/2667/2684, the interpreted `.music` path at 3336-3355, `musicQuery` at 752-779,
  `VoiceSessionStateMachine` states/timer at 9-17/93-96/183-203, the 60 s voice watchdog, the
  `IntentPromptTests` 3,000-character pin, `maxTokenCount: 1024`). Remaining study §10 line
  references not cited above are study-derived.
- Exact user-facing copy (probe wording, default-play phrase, cancel/escape lines, honest lines)
  is OD-M1/OD-M2/design-dependent; the Nepali/English examples in this set are illustrative and
  localization-bound (the keys must exist in both languages — NFR-MTC-006).
- The curated catalog's exact contents (e.g. the bhajan deity list) are data refined at design
  time; the requirement binds the catalog's existence, on-device sourcing, localisability and
  canonicalisation behaviour (FR-MTC-015).
- "v16"/"v17" are the study's and constitution's iteration labels for the existing slot-canonical
  fine-tune and the Phase 2 follow-up fine-tune; the actual artifacts land via the Phase 2 training
  iteration (FR-MTC-018) — nothing in Phase 1 depends on a training run.
- The project's known pre-existing test failures (unrelated to this feature) remain the baseline
  for NFR-MTC-012; the feature's own suites and touched suites must pass, with baseline failures
  recorded rather than silently included or excluded.
- The 45 s deadline is the existing confirmation timer value
  (`VoiceSessionStateMachine.confirmationTimeoutSeconds = 45`); reuse mechanics are design's to
  fix, the value is binding.
- `DialogueManager`/`DialogueFrame`/`awaitingSlotAnswer`/the curated catalog were confirmed
  absent from the worktree source at requirements time — they are genuinely new surfaces.

## Out of scope

Explicitly not in scope (feature constitution "Out of scope (must not change)" plus the workflow
scope comment's explicit non-goals) — recorded so nothing is silently half-built:

- **Open-ended conversation/chat** — the fine-tunes have no conversational mode; stage-3 chat was
  never done and shipped-brain chat is a known problem. Probes are the only new dialogue.
- **Raw transcript history in prompts** — the 1024-token ceiling (study §5.1); dialogue state
  lives in the app (NFR-MTC-002).
- **Model-generated probe text** — probes are template-generated, ne/en (FR-MTC-016).
- **Cloud / BYO-LLM anything** — no new egress, on-device stance unchanged (NFR-MTC-003).
- **Persistent dialogue state across sessions** — in-memory frames only; cold start has no frame
  (FR-MTC-001).
- **Reminder/calendar changes in Phase 1** — those turns are unchanged until Phase 3 and OD-M4
  (FR-MTC-019 Phase 1 guard).
- **Android** — no platform scope beyond the existing iOS app.
- **Emergency/medication behaviour changes** — none of any kind; emergency precedence is
  preserved absolutely (FR-MTC-011).
- **Any new compliance regime, permission, store or egress host** (NFR-MTC-012).

## Related

- Consolidated copy: [`../define-requirements.md`](../define-requirements.md)
- Locked snapshot: [`../define-requirements.lock.yaml`](../define-requirements.lock.yaml)
- Feature constitution: [`../multi-turn-conversation/constitution.md`](../multi-turn-conversation/constitution.md)
- Feature workflow (scope comment): [`../multi-turn-conversation/workflow.yaml`](../multi-turn-conversation/workflow.yaml)
- Owner's feasibility study: [`../../docs/multi-turn-conversation-feasibility.md`](../../docs/multi-turn-conversation-feasibility.md)
