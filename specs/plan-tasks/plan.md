# Task Breakdown — Multi-Turn Conversation (Phase 1)

**Feature:** `multi-turn-conversation` (brownfield, iOS only)
**Worktree:** `elderly-ai-assistant-multi-turn-conversation` · branch `feat/multi-turn-conversation`
**Task:** `plan-tasks` (contract `task_breakdown_l3`) · **Agent:** `lead-engineer`
**Inputs:** `specs/design-l1.md` (16 ADRs), `specs/design-l2.md` (1005 lines,
13 components C-MTC-01..C-MTC-13), `specs/review-l2.md` (GO; F-1..F-4, C-1..C-5),
`specs/security-design-review.md` (SECURITY-GO; M-1..M-5, V-1..V-4, E1..E8,
R1..R5), `specs/define-requirements.md` (20 FR-MTC + 12 NFR-MTC, 97 Gherkin
scenarios), the feature constitution `specs/multi-turn-conversation/constitution.md`
and the project `constitution.md`.

## Summary

- **Task groups:** 5 (TG-24..TG-28).
- **Total tasks:** 19 (T-125..T-143), 0 subtasks — every task is a single-owner leaf
  task (rationale under Planning assumptions).
- **Estimated effort:** ~41 developer-days nominal; ~23–26 days elapsed with two
  developers; sequential floor ~41 days. Critical-path floor 23 days.
- **Critical path:** T-130 → T-131 → T-133 → T-136 → T-139 → T-141 → T-142.
- **Requirement coverage:** all 20 FR-MTC and 12 NFR-MTC documents link from at
  least one task; the 97 requirement scenarios mirror into the task acceptance
  criteria. FR-MTC-018 and FR-MTC-019 link only through their Phase-1 guard
  scenarios (zero prompt edits; reminder/calendar untouched); their build-out is
  in Later phases, not in this plan. Map below.
- **Security work:** M-1..M-5 are folded into named tasks as Definition-of-done
  pins; V-1..V-4 are verify-and-record DoD lines; E1..E8 each have a producer
  task and a DoD line (tables below); the accepted residuals R1..R5 are recorded,
  not tasked. No BLOCKERs exist.
- **Release gate:** `ios/tools/` + `check-release-log-safety.sh` (wired into
  `ios/build.sh` after `xcodegen generate`) is binding. T-138 extends
  `FEATURE_ROOTS` with the four new dialogue source files and adds the per-root
  fixture entries; T-137 adds the six new `LogSanitiser.allowedKeys` entries
  (M-4: six new keys, `reason` reused).
- **Scope:** Phase 1 only (FR-MTC-001..017 plus the FR-MTC-020 device-validation
  protocol). No Phase 2/3 code, no prompt or model-stack change, no new network
  egress, no reminder/calendar change, no post-MVP additions, iOS only.
- **Prerequisite:** the Phase 0 PR #156 device smoke is outstanding; it is
  recorded as the first step of T-143, not as a task.

### Recommended execution order and parallelism

Dependencies point at lower IDs only, so ascending ID order is a valid
topological order. Waves are file-disjoint within each wave.

| Wave | Tasks | Note |
|------|-------|------|
| W1 | T-125, T-126, T-127, T-128, T-129, T-130, T-135, T-137 | all foundational, no deps, disjoint files |
| W2 | T-131, T-132 | pure answer path + candidate builder (need W1 types) |
| W3 | T-133, T-138 | router interception (first integration point) + release-gate extension |
| W4 | T-134, T-136 | probe triggers + coordinator wiring (same-file pairs are sequential by dependency, never parallel) |
| W5 | T-139, T-140, T-143 | security suites + DV protocol (need the wired feature and the gate) |
| W6 | T-141 | end-to-end acceptance + full-suite sweep |
| W7 | T-142 | security evidence index — closes the record for `security-test` |

### Critical path

```
T-130 ──► T-131 ──► T-133 ──► T-136 ──► T-139 ──► T-141 ──► T-142
 rule       answer     router    wiring    security   acceptance  evidence
 (2.5d)     (4d)       (5d)      (4d)      (3.5d)     (2.5d)      (1.5d)   = 23d
```

The chain starts at the keyword-rule provenance work because both the
classifier's scaffold/marker vocabulary and the degenerate trigger derive from
it; it then passes through the pure answer path, the single router integration
point, the coordinator wiring that makes the answer window real, the security
suites that prove the trap and injection properties, the end-to-end acceptance
sweep and the evidence index. T-125/T-126/T-128 feed T-131 in parallel; T-134
and T-136 run in the same wave off T-133; T-135 (state machine) is an
independent W1 unit that T-136 consumes. Nothing on the chain parallelises
within itself, and T-143's DV execution (owner/device-dependent) is not on the
engineering chain but does gate final sign-off.

### Key risks

1. **T-133 (CRITICAL) — interception placement and emergency precedence.** The
   new block sits between the confirmation hook's closing brace
   (`CommandRouter.swift:886`) and the safety net (`:897`); the emergency block
   (`:779-783`) stays absolute with only a post-dispatch, side-effect-only frame
   clear. Mitigation: placement test (answer turn never reaches the interpreter
   or cache), emergency dispatch pinned with the clear forced to a no-op,
   barge-in falls through and executes exactly once, and the hook body stays
   byte-identical.
2. **T-130 / T-131 (HIGH) — capture ladder and extractor byte-parity.** The
   classifier's V1–V14 vectors and the `musicQuery` wrapper's byte-identical
   return values are the regression surface for FR-MTC-002/005/006. Mitigation:
   one named test per vector, a provenance test per fallback step, and a
   wrapper-parity test over the existing fixtures.
3. **T-136 (HIGH) — window lifecycle wiring (M-1/M-2).** The shipped
   `handlePipelineState` guard covers only `.awaitingConfirmation`, and four
   confirmation arming sites transition the session directly. Mitigation: the
   named guard extension and the funnel/resolve-at-exit observer are DoD pins,
   with pipeline-events-mid-window, Talk-mid-window and watchdog-mid-window
   tests in T-139.
4. **T-139 / T-140 (HIGH) — security evidence honesty.** The hostile corpus and
   the trap matrix are the E1–E3/E8 evidence; a paper test would pass review and
   fail the gate's purpose. Mitigation: one named test per corpus row, a plan
   requirement that each case asserts the observable effect (no interpreter, no
   cache, no crash, frame cleared), and the T-142 index tying each E-row to its
   producer output.
5. **T-143 (MEDIUM) — owner/device dependency.** No simulator or agent
   substitute satisfies FR-MTC-020. Mitigation: the protocol is authored in W5;
   execution is scheduled against the owner's Anzaan device; a failed DV item
   blocks final sign-off.

## Contents

- [tasks/index.md](tasks/index.md) — all task groups and the ID numbering convention
- [TG-24 — Dialogue Frame Foundations](tasks/TG-24-dialogue-frame-foundations/index.md)
- [TG-25 — Answer Classification and Merge](tasks/TG-25-answer-classification-and-merge/index.md)
- [TG-26 — Router Interception and Window State](tasks/TG-26-router-interception-and-window-state/index.md)
- [TG-27 — Observability, Release Gate and Security Evidence](tasks/TG-27-observability-release-gate-and-security-evidence/index.md)
- [TG-28 — Acceptance, Evidence and Device Protocol](tasks/TG-28-acceptance-evidence-and-device-protocol/index.md)

### Task groups

| Group | Title | Tasks | Effort | Risk profile |
|-------|-------|-------|--------|--------------|
| TG-24 | Dialogue Frame Foundations | 5 | ~6.5 d | 1x HIGH, 3x MEDIUM, 1x LOW |
| TG-25 | Answer Classification and Merge | 3 | ~7.5 d | 2x HIGH, 1x MEDIUM |
| TG-26 | Router Interception and Window State | 4 | ~14.5 d | 1x CRITICAL, 3x HIGH |
| TG-27 | Observability, Release Gate and Security Evidence | 4 | ~7.5 d | 3x HIGH, 1x MEDIUM |
| TG-28 | Acceptance, Evidence and Device Protocol | 3 | ~5 d | 2x HIGH, 1x MEDIUM |

### All tasks

| ID | Title | Group | Depends on | Effort | Risk |
|----|-------|-------|------------|--------|------|
| [T-125](tasks/TG-24-dialogue-frame-foundations/T-125-dialogue-manager-frame-core.md) | Dialogue frame, manager and probe composer | TG-24 | — | M | HIGH |
| [T-126](tasks/TG-24-dialogue-frame-foundations/T-126-dialogue-option-catalog.md) | Curated option catalog and bundled resource | TG-24 | — | M | MEDIUM |
| [T-127](tasks/TG-24-dialogue-frame-foundations/T-127-intent-transcript-preparation.md) | Shared input-seam helper (`IntentTranscriptPreparation`) | TG-24 | — | S | MEDIUM |
| [T-128](tasks/TG-24-dialogue-frame-foundations/T-128-barge-in-predicate-access-widenings.md) | Barge-in predicate access widenings (L2-D2) | TG-24 | — | S | LOW |
| [T-129](tasks/TG-24-dialogue-frame-foundations/T-129-dialogue-localisation-keys.md) | `dialogue.*` localisation inventory (17 keys) | TG-24 | — | S | MEDIUM |
| [T-130](tasks/TG-25-answer-classification-and-merge/T-130-keyword-intent-rule-provenance.md) | Keyword-rule provenance, near-matches and markers | TG-25 | — | M | HIGH |
| [T-131](tasks/TG-25-answer-classification-and-merge/T-131-dialogue-answer-path-classification.md) | Answer path: classification, merge and barge-in | TG-25 | T-125, T-126, T-128, T-130 | L | HIGH |
| [T-132](tasks/TG-25-answer-classification-and-merge/T-132-dialogue-candidate-builder.md) | Candidate assembly for did-you-mean probes | TG-25 | T-125, T-126, T-130 | S | MEDIUM |
| [T-133](tasks/TG-26-router-interception-and-window-state/T-133-router-dialogue-interception.md) | Router interception block, protocol and execution | TG-26 | T-125, T-126, T-128, T-131 | XL | CRITICAL |
| [T-134](tasks/TG-26-router-interception-and-window-state/T-134-degenerate-triggers-and-did-you-mean.md) | Degenerate-music triggers and did-you-mean upgrades | TG-26 | T-130, T-132, T-133 | L | HIGH |
| [T-135](tasks/TG-26-router-interception-and-window-state/T-135-voice-session-awaiting-slot-answer.md) | `awaitingSlotAnswer` state and 45 s window | TG-26 | — | M | HIGH |
| [T-136](tasks/TG-26-router-interception-and-window-state/T-136-app-coordinator-dialogue-wiring.md) | Coordinator wiring: ownership, funnels, timeout | TG-26 | T-127, T-133, T-135 | L | HIGH |
| [T-137](tasks/TG-27-observability-release-gate-and-security-evidence/T-137-log-sanitiser-dialogue-keys.md) | `LogSanitiser` dialogue metadata keys (M-4) | TG-27 | — | S | MEDIUM |
| [T-138](tasks/TG-27-observability-release-gate-and-security-evidence/T-138-release-log-gate-dialogue-roots.md) | Release log gate: feature roots and fixtures | TG-27 | T-125, T-126, T-131, T-132 | S | HIGH |
| [T-139](tasks/TG-27-observability-release-gate-and-security-evidence/T-139-hostile-corpus-and-trap-suites.md) | Hostile-answer corpus and trap matrix suites | TG-27 | T-131, T-133, T-134, T-136 | L | HIGH |
| [T-140](tasks/TG-27-observability-release-gate-and-security-evidence/T-140-cache-bypass-log-and-egress-suites.md) | Cache-bypass, log-capture and egress suites | TG-27 | T-133, T-134, T-136, T-137, T-138 | M | HIGH |
| [T-141](tasks/TG-28-acceptance-evidence-and-device-protocol/T-141-end-to-end-acceptance-and-regression-sweep.md) | End-to-end acceptance and no-regression sweep | TG-28 | T-133, T-134, T-136, T-139, T-140 | M | HIGH |
| [T-142](tasks/TG-28-acceptance-evidence-and-device-protocol/T-142-security-evidence-index.md) | Security evidence index (E1..E8, V-1..V-4, R1..R5) | TG-28 | T-138, T-139, T-140, T-141 | S | HIGH |
| [T-143](tasks/TG-28-acceptance-evidence-and-device-protocol/T-143-device-validation-protocol.md) | DV-1..DV-5 protocol and record (FR-MTC-020) — PROTOCOL | TG-28 | T-136, T-138 | S | MEDIUM |

### Condition fold-ins (review-l2)

| Condition | Where it lands |
|-----------|----------------|
| C-1 answer-window default without a type-level access | T-125 (init takes the window by injection) + T-136 (the coordinator sources it from the session-machine instance; 45 stays single-source at `:95`, no new literal) |
| C-2 news-parity anchors `:1210-1217` relaxed / `:1131-1138` strict | T-133 (news candidate execution mirrors the real relaxed arm) |
| C-3 invalid-answer `reason` via direct event construction | T-133 (DoD: the metadata is never dropped to compile) |
| C-4 key counts corrected to 17 | T-129 (exactly 17 keys; `dialogue.timeout` deliberately absent) |
| C-5 bind the taken rephrase command; comment the nil-seam parity | T-134 (bind `taken` at `:806`) + T-127 (parity comment in the helper) |

### Security fold-ins (security-design-review)

| Item | Where it lands |
|------|----------------|
| M-1 pipeline state can close the window | T-136 (guard extension + named resolve observer) + T-139 (pipeline-events-mid-window row) |
| M-2 four arming sites transition around the funnel | T-136 (route through the funnel or resolve at site) + T-139 (Talk/watchdog-mid-window rows) |
| M-3 answer sanitiser source | T-127 (helper semantics) + T-136 (production seam pinned non-nil) + T-139 (corpus run through a non-nil seam) |
| M-4 six new keys; `reason` closed tokens | T-137 (keys + vocabularies) + T-133 (direct event construction) + T-138 (gate) + T-140 (allow-list diff) |
| M-5 candidate index bounds | T-131 (total `classify`/`matchCandidate`) + T-133 (executor bounds check) + T-139 (hostile index row) |
| V-1 gibberish mid-frame ordering recorded | T-133 (gibberish row consumes no attempt) + T-142 (recorded) |
| V-2 debug lanes: the diff adds no console write | T-133 / T-134 / T-136 (DoD lines) + T-142 (recorded) |
| V-3 answer flow vs persistence re-verified | T-140 (re-verified after implementation) |
| V-4 sanity guard placement recorded | T-133 + T-142 |
| R1..R5 accepted residuals | Recorded in T-142; not tasked |

### Security evidence obligations → producer task and DoD line

| # | Obligation | Producer | DoD line (task file) |
|---|-----------|----------|----------------------|
| E1 | Emergency answer mid-frame dispatches; frame cleared `.emergency`; dispatch independent of the clear | T-139 | "emergency dispatch proven with the clear forced to a no-op" |
| E2 | Hostile answer corpus through a non-nil seam | T-139 | "every corpus row resolves to the frame's admissible effects or a re-probe/close; no interpreter, no cache, no crash" |
| E3 | Trap matrix incl. pipeline/Talk/watchdog mid-window | T-139 | "every trap row reaches a terminal resolution; no half-open window after 45 s" |
| E4 | Log capture over a full dialogue; gate exits 0 with the new roots and fixtures | T-138 (+ T-140) | "the gate exits 0 including its fixtures suite over the four new roots" |
| E5 | Allow-list diff and closed value vocabularies | T-137 (+ T-140) | "exactly six new keys; closed tokens; the unlisted-key drop remains in force" |
| E6 | Egress: zero new network calls in the feature's files | T-140 | "egress audit: no new host, endpoint or transport construction" |
| E7 | Degraded brain: deterministic merge; no Phase 2 clause in Phase 1 | T-131 (+ T-141) | "brain-absent merge produces the same command; prompt pins show zero prompt change" |
| E8 | Cache/history boundary | T-140 | "no answer text reaches `pendingTranscript` or the intent cache" |
| — | Index tying every row to its producer output | T-142 | "each E-row records producer task, test/command and result" |

### Requirement map

| Requirement | Tasks |
|-------------|-------|
| FR-MTC-001 frame lifecycle | T-125, T-133, T-136 |
| FR-MTC-002 degenerate detection | T-130, T-134 |
| FR-MTC-003 slot-fill probe | T-125, T-126, T-134 |
| FR-MTC-004 did-you-mean probe | T-132, T-134 |
| FR-MTC-005 answer capture | T-131 |
| FR-MTC-006 merge and execution | T-127, T-131, T-133, T-141 |
| FR-MTC-007 probe budget | T-125, T-132, T-133, T-134 |
| FR-MTC-008 escape | T-131, T-133 |
| FR-MTC-009 interception | T-133, T-136 |
| FR-MTC-010 cancel | T-131, T-133 |
| FR-MTC-011 emergency precedence | T-133, T-136, T-139 |
| FR-MTC-012 barge-in | T-128, T-131, T-133 |
| FR-MTC-013 timeout | T-133, T-135, T-136 |
| FR-MTC-014 `awaitingSlotAnswer` | T-135, T-136 |
| FR-MTC-015 catalog | T-126 |
| FR-MTC-016 template probes | T-125, T-129 |
| FR-MTC-017 cache bypass | T-133, T-140 |
| FR-MTC-018 Phase 2 v17 clause (guard only) | T-141 (Phase-1 guard; build-out in Later phases) |
| FR-MTC-019 Phase 3 rollover (guard only) | T-141 (Phase-1 guard; build-out in Later phases) |
| FR-MTC-020 DV gate | T-143 |
| NFR-MTC-001 turn envelope | T-135, T-136 |
| NFR-MTC-002 prompt budget | T-141 |
| NFR-MTC-003 no new egress | T-126, T-140 |
| NFR-MTC-004 log safety | T-133, T-137, T-138, T-140, T-142 |
| NFR-MTC-005 degraded brain | T-131, T-136, T-143 |
| NFR-MTC-006 localisation | T-126, T-129 |
| NFR-MTC-007 jetsam stability | T-136, T-143 |
| NFR-MTC-008 sanitisation and injection safety | T-127, T-131, T-133, T-139, T-142 |
| NFR-MTC-009 voice-only accessibility | T-125, T-129 |
| NFR-MTC-010 trap resistance | T-132, T-133, T-135, T-136, T-139 |
| NFR-MTC-011 KV-prefix stability | T-141 (Phase-1 pin: zero prompt change) |
| NFR-MTC-012 compliance and release gates | T-127, T-128, T-130, T-134, T-136, T-137, T-138, T-140, T-141, T-142, T-143 |

## Later phases and marked gaps

- **Phase 2 — FR-MTC-018 (follow-up NLU v17 + frame clause):** no implementation
  task in this plan. The interfaces are pinned in design-l2 §19
  (`InterpreterContext.frameClause`, the fifth prompt interpolation, the seed
  mirror and digest updates) and land only with the v17 training change. The
  Phase-1 guard — a release without the training artifacts injects no clause —
  is pinned by T-141 (zero prompt-file edits; prompt digests, the 2_506 baseline
  and the 3_000 ceiling stay green).
- **Phase 3 — FR-MTC-019 (reminder/calendar rollover):** no task. The frame
  interfaces are slot-parametric so the rollover is additive (design-l2 §20, §24
  of the L1). The Phase-1 guard — reminder/calendar turns unchanged, no frame
  opened — is pinned by T-141's no-regression sweep.
- **Phase 0 prerequisite:** the PR #156 device smoke (conversation → no jetsam →
  JetsamEvent pull) is outstanding; recorded as the first step of T-143, not as a
  task.
- **OD-M1..OD-M4 remain owner-facing** with the design's defaults implemented as
  configuration (2 probes; curated on-device catalog; Phase 1 first; Phase 3
  separate). Owner confirmation rides the T2 final sign-off; changing OD-M1 is a
  config-value change in T-125, not a redesign.
- **Copy review:** the ne/en copy of the 17 `dialogue.*` keys is draft
  (design-l2 §6 gap 2); T-129 carries the key inventory for review without
  blocking implementation.
- **Catalog alias lists** are data, extendable without code (design-l2 §6 gap 3);
  T-126 ships the v1 schema and the curated bhajan group.
- **DV wording:** the constitution's DV table plus design-l1 §6 verbatim is the
  record for each item; T-143 adopts it rather than re-inventing item text.

## Planning assumptions

- **ID numbering.** This tree accumulates across features (TG-01..TG-10,
  TG-14..TG-17, TG-18..TG-23 on disk from earlier features). This feature uses
  **TG-24..TG-28** and **T-125..T-143**; the next feature continues at TG-29 /
  T-144.
- **No subtasks.** Every task is a single-owner leaf. The natural split
  candidates share single files: the router's interception and its probe
  triggers both edit `CommandRouter.swift`, so they are two sequential tasks
  (T-133, T-134) rather than parallel subtasks; the coordinator wiring is one
  file (T-136). If the implement stage needs finer units, it should split by
  file, not by scenario.
- **XcodeGen, not hand-edited pbxproj.** New Swift files are picked up by the
  `ElderlyAssistant`/`ElderlyAssistantTests` source globs; only the new JSON
  resource needs an explicit `ios/project.yml` entry plus `xcodegen generate`
  (T-126). This supersedes design risk 9's pbxproj concern.
- **Test baseline.** Master's unit gate carries ~21 pre-existing failures in
  unrelated suites. DoD lines ask for the unit's focused suites green and no
  new full-suite failures against that recorded baseline; T-141 records the
  end-of-feature full-suite run.
- **Anchors.** Task files cite component IDs (C-MTC-NN) and the verified line
  anchors from design-l2; the anchors are re-verified at implementation time
  against the branch head.
- **Confidence and review.** The workflow's implement stage runs unit_based with
  paired review (different agent) at confidence 0.85 and max 5 rework
  iterations; every task's DoD assumes code review before merge.
- **Gate scope.** The binding local release check is `ios/build.sh` including
  the log-safety gate; iOS only, no other platform scope.

## Owner actions (not agent work)

- **OD-M1..OD-M4 confirmation** at the T2 final sign-off (defaults implemented
  meanwhile, per design-l1 §5).
- **Copy review** of the 17 ne/en `dialogue.*` strings (draft in design-l2 §16).
- **DV-1..DV-5 execution on Anzaan** and the Phase 0 PR #156 smoke, per the
  T-143 protocol; a failed item blocks final sign-off until fixed and re-run.
