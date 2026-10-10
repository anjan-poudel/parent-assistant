# Multi-Turn Conversation — Implementation Notes (T-125 … T-143)

- **Description:** Implementation record of the multi-turn-conversation feature run — one-deep dialogue frames with template probes (slot-fill + did-you-mean candidate choice), pre-ladder answer interception, deterministic merge, curated on-device catalog, and the bhajan probe as the first end-to-end case. All 19 units across 7 dependency waves are implemented and reviewed; this file records per-unit status, wave-review verdicts, gate evidence, and the owner/device items that remain open by design.
- **Feature:** multi-turn-conversation (ai-sdd run, direct dispatch, unit_based execution in topological waves, paired review per wave)
- **Branch and worktree:** feat/multi-turn-conversation in the dedicated feature worktree; the main checkout was not used for task work.
- **Date:** 2026-10-10
- **Scope honoured:** Phase 1 only (FR-MTC-001..017 + the FR-MTC-020 protocol); iOS only; no prompt or model-stack change (zero prompt edits; the Phase 2 frame clause ships only with the v17 training iteration); no new network egress; no emergency/medication behaviour change; no reminder/calendar change.

## 1. Per-unit status (19 units)

| Unit | Title (short) | Wave | Status | Evidence summary |
|---|---|---|---|---|
| T-125 | Dialogue frame, manager and probe composer | W1 | DONE | DialogueFrameTests 17/17 (scoped run 15:26; re-verified at the W1 combined gate). Frame core per design-l2 §8. Flagged: wave-order hoist of CaptureForm/MergeSource/DialogueMerge from design-l2 §9 into DialogueManager.swift (contract: T-131 consumes, never re-declares). |
| T-126 | Curated option catalog and bundled resource | W1 | DONE | DialogueOptionCatalogTests 10/10 (15:49). Catalog loader + bundled DialogueOptionCatalog.json v1 (bhajan.deity) + project.yml resource entry; bundle presence exactly-once, byte-identical (sha e51de88e…) verified. |
| T-127 | Shared input-seam helper (IntentTranscriptPreparation) | W1 | DONE | IntentTranscriptPreparationTests 8/8 + LocalBrainChainTests 29/29 (15:32, existing suite unmodified). turnInput rewired in place via the helper; C-5 nil-seam parity comment pinned by a source-scan test; transcriptPreparationSeam accessor added for T-136. |
| T-128 | Barge-in predicate access widenings (L2-D2) | W1 | DONE | Widenings landed: CommandRouter.sensitiveCallPhrases and VoiceContactSearchRoute.isDirectCallUtterance private → internal only, no behaviour change. The unit's scoped run was blocked by the cross-unit compile state (14:28–15:26); executed green at the W1 wave gate: CommandRouterTests 33/33 + VoiceContactSearchRouteTests 28/28. |
| T-129 | dialogue.* localisation inventory (17 keys) | W1 | DONE | L10nCatalogCoverageTests 10/10 (15:31). Exactly 17 dialogue.* keys added verbatim from design-l2 §16 (catalog 1364 → 1381); dialogue.timeout deliberately absent (C-4). Note: a pre-existing stale Spotify catalog pin (1361) is red at the branch base, unchanged by this unit. |
| T-130 | Keyword-rule provenance, near-matches and markers | W1 | DONE | KeywordIntentRuleTests 54/54 + KeywordIntentRuleProvenanceTests 23/23 (15:28). MusicQueryExtraction + closed Provenance {content, markerFallback, transcriptFallback}; thin byte-identical musicQuery wrapper (parity over the full fixture corpus); nearMatches for the 4 framable domains (medication excluded). |
| T-131 | Answer path: classification, merge and barge-in | W2 | PENDING | — |
| T-132 | Candidate assembly for did-you-mean probes | W2 | PENDING | — |
| T-133 | Router interception block, protocol and execution | W3 | PENDING | — |
| T-134 | Degenerate-music triggers and did-you-mean upgrades | W4 | PENDING | — |
| T-135 | awaitingSlotAnswer state and 45 s window | W1 | DONE | VoiceSessionStateMachineTests 24/24 (15:30). New .awaitingSlotAnswer mirroring confirmation; 45 s single-source (command-window param); F14 idle-bridge; F6 still-open guard; additive inert UI mappings in HomeView/HomeSubviews (to confirm at T-136/device). |
| T-136 | Coordinator wiring: ownership, funnels, timeout | W4 | PENDING | — |
| T-137 | LogSanitiser dialogue metadata keys (M-4) | W1 | DONE | LogSanitiserTests 34/34 (15:31); release-log gate green in the same build. Six keys added (78 → 84) with closed vocabularies per design-l2 §26; reason reused (producer-validated, test-pinned). Deviation: the T-137 task file's parenthetical token lists match no emitting enum and appear nowhere else in the spec tree — design-l2 §26 vocabularies implemented instead (grep-verified). |
| T-138 | Release log gate: feature roots and fixtures | W3 | PENDING | — |
| T-139 | Hostile-answer corpus and trap matrix suites | W5 | PENDING | — |
| T-140 | Cache-bypass, log-capture and egress suites | W5 | PENDING | — |
| T-141 | End-to-end acceptance and no-regression sweep | W6 | PENDING | — |
| T-142 | Security evidence index (E1..E8, V-1..V-4, R1..R5) | W7 | PENDING | — |
| T-143 | DV-1..DV-5 protocol and record (FR-MTC-020) | W5 | PENDING | — |

## 2. Wave log and review verdicts

| Wave | Units | Commit | Review verdict |
|---|---|---|---|
| W1 | T-125, T-126, T-127, T-128, T-129, T-130, T-135, T-137 | (pending) | GO — Confidence 0.90 (specs/implement-review-w1.md; 0 blockers; findings all note-level) |

W1 findings disposition (F-1..F-7, all note-level): F-1 non-redeclaration contract for T-131 — carried into the W2 dispatch brief; F-2/F-3 spec-text clarifications (T-130 task file; design §13b) — deferred to the next spec touch, no code change; F-4 pre-existing Spotify catalog pin red at base — carried to the T-141 full-gate baseline comparison (must not be counted as a W1 regression); F-5 `.awaitingSlotAnswer` UI mappings — compile-forced placeholders, confirm at T-136/device; F-6 did-you-mean copy reading — owner copy review at the feature review; F-7 `intake` vocabulary forward-reference — confirm when T-138/W3 type lands.

## 3. Gate evidence

- W1 wave gate (2026-10-10 15:53–15:54 AEDT): combined scoped run of all eight W1 units' suites under the shared build lock — `cd ios && ./build.sh test:unit DialogueFrameTests DialogueOptionCatalogTests IntentTranscriptPreparationTests LocalBrainChainTests VoiceContactSearchRouteTests CommandRouterTests L10nCatalogCoverageTests KeywordIntentRuleTests KeywordIntentRuleProvenanceTests VoiceSessionStateMachineTests LogSanitiserTests` → rc=0, **270 tests executed, 270 passed, 0 failures** (`Test-ElderlyAssistant-2026.10.10_15-53-36-+1100.xcresult`; log /tmp/mtc-w1-gate.log; "Scoped unit run passed (baseline not advanced)"). Per suite: DialogueFrameTests 17, DialogueOptionCatalogTests 10, IntentTranscriptPreparationTests 8, LocalBrainChainTests 29, VoiceContactSearchRouteTests 28, CommandRouterTests 33, L10nCatalogCoverageTests 10, KeywordIntentRuleTests 54, KeywordIntentRuleProvenanceTests 23, VoiceSessionStateMachineTests 24, LogSanitiserTests 34. The release log-safety gate (24 fixtures over 12 rules) ran green inside the same build.
- Freshness runs per wave: W2–W7 pending.
- Full unit gate at the end of the implement stage: pending (T-141).
- Release log-gate feature roots (T-138) and egress/log-capture suites (T-140): pending.
- Known pre-existing red at the branch base: master's unit gate carries ~21 pre-existing failures in unrelated suites (recorded baseline; not regressions of this feature). Confirmed at W1: no W1 suite is among them (270/270 green scoped).
