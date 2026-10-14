# Task Breakdown — Conversational Nepali Replies (CNR)

Feature: `conversational-nepali-replies` — worktree `/Users/anjan/workspace/projects/elderly-ai-assistant-conversational-nepali-replies` (branch `feat/conversational-nepali-replies`).
Decomposition source: `specs/design-l1.md` (combined L1+L2 design of record, 2026-10-14), read against `specs/define-requirements.md` (29 FR-CNR, 11 NFR-CNR) and the feature workflow `specs/conversational-nepali-replies/workflow.yaml` (2026-10-14 lean-chain directive).

## Summary

- **Task groups (Jira epics):** 6 — TG-34 … TG-39.
- **Total tasks:** 27 (leaf-task-only; 0 subtasks — the unit planner keys units on the leading `T-<digits>` token, so subtask files would collide).
- **Estimated effort:** about **50.5 developer-days nominal** (P0 runtime ≈ 20.0, P1 training ≈ 16.0, release/acceptance/device ≈ 4.5, P2 polish + feasibility statement ≈ 10.0). Realistically about **4 to 5 weeks with two developers** working the waves, including unattended training-box time and one Anzaan device session.
- **Execution mode:** `unit_based` with default wave parallelism (`implement.unit_execution.plan_task_id: plan-tasks`); the confidence overlay (threshold 0.85) and `max_rework_iterations: 5` are the only implement overlays. **No review or security-gate tasks exist in this plan** — the 2026-10-14 lean chain (design-l1 combined, review gates dropped, one advisory non-blocking security pass at the final sign-off) is the operating basis; the hard safety gates are enforced as code by T-181/T-182 and by the implementation tests.
- **Critical path:** T-166 → T-178 → T-179 → T-180 → T-182 → T-183 → T-184 → T-186 → T-187 → T-188 → T-192 — about 23 days, dominated by the P1 chain. With the P2 legs descoped, the path shortens to about 19 days (T-166 → … → T-187).
- **Ordering note (OD-3):** the P0 runtime slice (TG-34, TG-35, TG-36, the T-185 gate and the T-186 sweep over runtime-only behaviour) is independently landable and depends on no P1 or P2 artifact. The design records the P0-versus-P1 sequencing preference as an open owner question (recorded, not decided); this plan preserves both orderings in the declared graph and does not presume the answer. See `amendments/amendment-3-lean-review-gates-and-od3-2026-10-14.md`.
- **Device-validation gate:** DV-1…DV-6 (T-187) is the feature's completion gate; without an Anzaan session every item is recorded BLOCKED with the reason and the feature stays outstanding.

## Contents

- [tasks/index.md](tasks/index.md) — the group table, ID numbering, dependency-line format and preconditions
- [TG-34 — Style Spec, Chat Decode and Persona Seams](tasks/TG-34-style-spec-chat-decode-and-persona-seams/index.md) — T-166, T-167, T-168
- [TG-35 — Grammar Guard, Prompt Mirrors and Localised Copy](tasks/TG-35-grammar-guard-prompt-mirrors-and-copy/index.md) — T-169, T-170, T-171
- [TG-36 — Cloud Chat Consent, Routing and Elder Surfaces](tasks/TG-36-cloud-chat-consent-routing-and-elder-surfaces/index.md) — T-172 … T-177
- [TG-37 — v17 Chat-Aware Training Suite](tasks/TG-37-v17-chat-aware-training-suite/index.md) — T-178 … T-184
- [TG-38 — Release Gate, Acceptance and Device Validation](tasks/TG-38-release-gate-acceptance-and-device-validation/index.md) — T-185, T-186, T-187
- [TG-39 — P2 Polish and Feasibility Honesty](tasks/TG-39-p2-polish-and-feasibility-honesty/index.md) — T-188 … T-192
- [amendments/](amendments/) — plan amendments for this run (amendment 3 records the lean-chain directive and the OD-3 status)
- Design and requirements inputs: `specs/design-l1.md`, `specs/define-requirements.md`, `specs/conversational-nepali-replies/workflow.yaml`

## Wave order

Waves are the dependency-safe parallel groups, computed as longest-path layering over each unit's declared dependency line; units in the same wave own disjoint declared files and can run concurrently. The unit planner re-derives membership at implement time and may push a unit later when a same-file conflict appears (T-177 before T-184 on the coordinator file), never earlier than shown.

| Wave | Units | What the wave delivers |
|------|-------|------------------------|
| 0 | T-166, T-172 | The style spec (single source) and the fail-closed consent gate — the two foundations nothing else waits on |
| 1 | T-167, T-168, T-169, T-171, T-173, T-178 | Both chat decode/persona seams, the guard core, the bilingual copy, the routing decision, the held-out chat set |
| 2 | T-170, T-174, T-175, T-176, T-179, T-181 | Prompt mirrors, the guard flag at the dispatch seam, the router chat lane, the consent prompt, the four-layer corpus, the chat gate harness |
| 3 | T-177, T-180 | Indicator/revocation/coordinator wiring, the provenance manifest |
| 4 | T-182, T-185 | Chat-variant config + full harness over one candidate; release log-safety gate coverage |
| 5 | T-183 | The v17 chat-aware QLoRA run and its gate evidence |
| 6 | T-184 | The versioned, reversible catalog swap (promotion only behind green gates) |
| 7 | T-186 | End-to-end acceptance, scoped sweep, the one full-suite run with the baseline named |
| 8 | T-187 | The DV-1…DV-6 protocol and record (executed or BLOCKED) |
| 9 | T-188, T-189, T-190, T-191 | The four owner-descopable P2 legs (each after the P1 swap is live and the DV protocol has run) |
| 10 | T-192 | The feasibility honesty statement for the sign-off package |

Phase view: P0 = the runtime units (TG-34 ... TG-36) with the release gate T-185 (wave 4) and the runtime half of T-186 (wave 7); P1 = the training suite TG-37 (waves 1-6, ending in the gated swap at wave 6); P2 = the four P2 legs and the honesty statement (waves 9-10).

## Critical path

T-166 (1.5) → T-178 (3) → T-179 (4) → T-180 (1.5) → T-182 (1.5) → T-183 (2.5) → T-184 (1.5) → T-186 (2) → T-187 (1.5) → T-188 (3) → T-192 (1) = **23 developer-days**.

The chain runs spec → held-out set → corpus → manifest → harness → run → swap → acceptance → device validation → first P2 leg → statement. It is dominated by the P1 training leg because the swap (T-184) is explicitly gated behind the run's evidence, and the P2 legs are gated behind the swap being live and the DV protocol having run (FR-CNR-026). The P0-only chain (T-166 → T-167 → T-170 → T-174 → T-177 ≈ 8.5 days to a landable runtime slice, plus T-185/T-186) is short — which is why the P0 slice can ship first under either OD-3 ordering. If the owner descopes P2, the tail closes at T-187 (about 19 days).

## Key risks

1. **Command-decode determinism regression on the shared model (T-167, CRITICAL).** The chat shape adds a per-turn temperature override on the same resident handle the command path uses; a chat turn leaking temperature into a command decode would break reminders, alarms and confirmations silently. Mitigation: per-turn re-assertion of every shape's parameters, byte-identical command decode pinned by test, DV-5 on device.
2. **Cloud chat egress without consent (T-172, T-173, T-174, T-175, CRITICAL).** Two egress surfaces (the routing lane and the guard escalation) make it possible to leak chat content after a decline or revocation. Mitigation: one decision function, fail-closed on every non-granted state, egress-disabled local lane for chat turns, spy tests asserting zero cloud attempts on the declined paths.
3. **Ship-mix contamination by a non-commercial source (T-180, CRITICAL).** A CC BY-NC research layer or a research-gated transcript reaching a shipped artifact is a compliance event. Mitigation: the manifest's ship/dev enforcement as code, the license registry as the assertion source, the manifest hash bound to the gate results.
4. **A flagged reply spoken anyway, or a false success (T-174, CRITICAL).** The guard's whole purpose is to stop a flagged reply and degrade honestly. Mitigation: the verdict carries no text (no rewrite path), flagged text asserted absent from every spoken path, `unavailable` → degraded event rather than a claimed verification.
5. **Safety-gate regression in the v17 variant (T-181, T-182, T-183, HIGH).** Emergency recall 1.00, abstention at or above 0.90 and closed-intent at or above 0.95 bind the swap. Mitigation: the full harness over one candidate behind one report, red gate = no swap, shortfalls reported rather than absorbed.
6. **Jetsam on the reference tier (T-167, T-184, T-190, HIGH).** A second handle or a per-turn reload would kill the app mid-conversation on the 6 GB tier. Mitigation: one resident handle, no second instance, tier admission measured for the 4B candidate.
7. **Held-out set leak (T-178, T-179, HIGH).** A golden turn in the training corpus invalidates the gate run. Mitigation: admission-time dedupe against the held-out file, exclusions reported, gate results voided on a proven leak.
8. **Prompt or persona drift between the spec and its consumers (T-166, T-170, HIGH).** Four consumers of one spec is exactly where copies appear. Mitigation: byte-identity mirror checks in the build (chat template, both personas, guard lexicons) and the pinned intent prompt asserted untouched.
9. **Device validation outstanding at sign-off (T-187, HIGH).** The completion gate cannot be satisfied by unit tests. Mitigation: the protocol is written and executable in one session; without a session every item is BLOCKED with a reason and the feature is reported outstanding.
10. **A P2 leg quietly skipped (T-188 … T-191, MEDIUM).** Descoping must never be silent. Mitigation: each leg completes with an explicit owner-descope record if descoped, and T-192 must account for every leg.
11. **A new content path outside the log gate's coverage (T-185, HIGH).** The gate only protects what it scans. Mitigation: coverage audit for every new content-rendering path, a seeded-violation demonstration, and event fields checked against the allowed-key set.

## Security-advisory mapping (advisory, non-blocking — final-sign-off pass)

The workflow's advisory security focus areas map to units as follows; findings are recorded with the sign-off, not treated as exit conditions, while each area's enforcement lives in the unit's own tests:

| Advisory focus area | Enforced by |
|---|---|
| Safety-gate regression on the shared model; versioned reversible catalog swap | T-167 (command determinism pinned), T-182, T-183 (gates over one candidate), T-184 (versioned entry, catalog-level rollback), T-187 (DV-5) |
| Cloud chat consent/disclosure (OD-12 shape); never blocks chat | T-172 (fail-closed gate), T-173 (single decision), T-175 (no-leak lane), T-176 (blocking prompt, local answer meanwhile), T-177 (indicator, revocation) |
| Credential + content hygiene (B2/T-050 precedent; no user content in logs or the `reply_grammar_flag` event) | T-168 (header-only key, payload scope), T-174 (event field set), T-175 (fallback event), T-185 (release log gate coverage) |
| Guard integrity: verify-never-rewrite; honest degradation | T-169 (verdict-only contract), T-170 (lexicon mirror), T-174 (escalate / safe template / degraded) |
| Data provenance: no CC BY-NC in a shipped artifact | T-179 (layer separation), T-180 (ship-mix enforcement, manifest hash), T-191 (consent-based transcripts only) |
| Prompt discipline: 1,024-token budget; seed byte-mirror | T-167 (budget unchanged, single handle), T-170 (byte-identity mirrors + budget check) |

## Requirement coverage

Functional requirements (FR-CNR-001 … 029), each satisfied by at least one unit:

| Requirement | Units |
|---|---|
| FR-CNR-001 style spec, single source, four consumers | T-166, T-167, T-168, T-169, T-170 |
| FR-CNR-002 persona upgrade, both seams | T-167, T-168, T-170 |
| FR-CNR-003 chat sampling: fixed seed, temp ~0.3, chat only | T-167, T-192 |
| FR-CNR-004 command decode determinism preserved | T-167, T-186, T-187 |
| FR-CNR-005 guard verify-never-rewrite | T-169, T-170, T-174 |
| FR-CNR-006 flag outcome, honest degradation | T-171, T-174 |
| FR-CNR-007 reply-grammar-flag telemetry, no content | T-174, T-185 |
| FR-CNR-008 cloud-first chat routing toggle | T-168, T-173, T-175, T-177 |
| FR-CNR-009 consent, disclosure, indicator, revocation | T-172, T-173, T-175, T-176, T-177 |
| FR-CNR-010 cloud chat egress scope | T-168, T-173, T-175 |
| FR-CNR-011 explicit Gemini chat temperature | T-168 |
| FR-CNR-012 credential and content hygiene | T-168, T-174, T-185 |
| FR-CNR-013 single-decode schema unchanged | T-167, T-175, T-186 |
| FR-CNR-014 router ladder and emergency gate unchanged | T-175, T-187 |
| FR-CNR-015 STT, permissions, data collection unchanged | T-177, T-186, T-191 |
| FR-CNR-016 v17 chat-aware QLoRA variant | T-179, T-182, T-183 |
| FR-CNR-017 four-layer corpus construction | T-179 |
| FR-CNR-018 ship-mix provenance manifest | T-180, T-191 |
| FR-CNR-019 held-out chat evaluation set | T-178, T-179 |
| FR-CNR-020 new chat gates | T-181, T-182 |
| FR-CNR-021 full gate harness before the swap | T-182, T-183, T-184 |
| FR-CNR-022 v17 catalog entry, versioned and reversible | T-184 |
| FR-CNR-023 chat prompt template discipline | T-170 |
| FR-CNR-024 feasibility honesty reporting | T-183, T-188 … T-191, T-192 |
| FR-CNR-025 DV completion gate | T-186, T-187 |
| FR-CNR-026 P2 DPO on judge preferences | T-188 |
| FR-CNR-027 P2 romanized Nepali chat | T-189 |
| FR-CNR-028 P2 4B tier via the per-device resolver | T-190 |
| FR-CNR-029 P2 consent-based real transcripts | T-191 |

Non-functional requirements (NFR-CNR-001 … 011):

| Requirement | Units |
|---|---|
| NFR-CNR-001 chat reply reproducibility | T-167, T-169 |
| NFR-CNR-002 listening-turn latency envelope | T-173, T-175, T-190 |
| NFR-CNR-003 memory and jetsam device tiers | T-167, T-184, T-187, T-190 |
| NFR-CNR-004 chat prompt token budget | T-167, T-170 |
| NFR-CNR-005 prompt template byte-mirror | T-166, T-170 |
| NFR-CNR-006 log safety | T-168, T-172, T-174, T-185, T-186 |
| NFR-CNR-007 telemetry content hygiene | T-174, T-177 |
| NFR-CNR-008 gate thresholds | T-181, T-182 |
| NFR-CNR-009 accessibility (voice-first, no internals) | T-171, T-176, T-177, T-187 |
| NFR-CNR-010 localisation ne/en | T-171, T-177 |
| NFR-CNR-011 compliance and release gates | T-172, T-180, T-185, T-186 |

Deferred items stayed deferred: the design's deferred list (catalog entry literal id, spec field-level schemas, final en/ne copy, voice revocation phrases, wave decomposition) has no standalone task; each is authored inside the unit that owns it (T-166, T-171, T-177, T-184). Post-MVP and out-of-scope items have no tasks.
