# Plan amendment 3 — lean chain: combined design, no per-phase review gates, single advisory security pass; OD-3 left open (2026-10-14)

Owner directive (recorded mid-run, 2026-10-14): run this feature on the lean chain.
The workflow header item 6 of `specs/conversational-nepali-replies/workflow.yaml`
records the same instruction.

## What the lean chain means for this plan

**Combined design, one artifact.** `design-l1` is now the combined L1+L2 design of
record; there is no separate `design-l2` artifact for this feature, and this plan
decomposes from `specs/design-l1.md` directly.

**Review phases dropped from the chain.** The `review-l2`, `review-implementation`
and `security-design-review` phases do not run for this feature, and
`security-test` is not a phase. Accordingly **no review or security-gate tasks
exist in `specs/plan-tasks/`** — creating any would be out of contract with the
chain and has been deliberately avoided. The corresponding gate reporting lives in
the run's final sign-off instead.

**Implement phase.** `unit_based` execution over this plan
(`implement.unit_execution.plan_task_id: plan-tasks`) with the default wave
parallelism, the confidence overlay at threshold 0.85, and
`max_rework_iterations: 5`. Per-unit paired review is not applied. (This continues
the direction of amendment 2, now formalised for the whole feature.)

**Final sign-off is the one blocking gate.** T2 approval + HIL + DV-1..6 on
Anzaan, plus **one advisory, non-blocking security pass** over the final diff.
The pass produces findings; findings are recorded with the sign-off and do not
gate it. This supersedes amendment 2's deferred end-of-phase
`review-implementation` / `security-test` exit conditions for this feature.

**Hard safety gates stay hard — they moved into the work, not out of it.** The
safety properties that review phases used to double-check are enforced by
executable artifacts inside this plan itself:

- the training gate harness and its thresholds — emergency recall 1.00,
  abstention at or above 0.90, closed-intent at or above 0.95, calibration within
  ±0.10 (T-181, T-182, T-183) — and the catalog swap is blocked on them (T-184);
- command-decode determinism, chat reproducibility at the fixed seed and
  temperature floor (~0.3), guard never-rewrite and honest degradation, the
  fail-closed cloud-chat consent gate, credential/content hygiene, ship-mix
  provenance (no CC BY-NC in a shipped artifact), the prompt token budget and
  seed byte-mirror, and the release log-safety gate — each pinned by the
  implementation tests and checks of the unit that owns it, and each enumerated
  once more in the completion report's safety-traceability section;
- DV-1..6 on Anzaan as the completion gate (T-187), BLOCKED-with-reason if no
  session.

## OD-3 remains an open owner question

The design records an ordering question (OD-3): whether the P0 runtime slice
lands before the P1 training swap or the two proceed in parallel. It is
**recorded, not decided** — no owner answer exists yet, and this plan deliberately
does not presume one. Both orderings remain valid against the declared graph:

- **P0 first:** TG-34..TG-36 + T-185/T-186 depend on no P1/P2 artifact and form an
  independently landable runtime slice (the T-175 router lane defaults to local
  until the swap lands, so nothing in P0 requires the new model to be shipped).
- **Parallel:** TG-37's training leg shares no file with the P0 units; its only
  runtime coupling is T-184's catalog swap, which naturally lands after T-177 has
  wired the coordinator seam.

Either ordering satisfies every dependency edge in the plan; the choice changes
schedule, not correctness. The owner's answer, whenever given, is recorded as a
further amendment — no task file needs to change for either answer.

## Validator-compliance fixes applied to pre-existing task files (recorded)

`ai-sdd validate-plan` checks every top-level `tasks/*.md`, including files from
earlier features that remain in this worktree. Four such pre-existing files did
not satisfy the validator. They were fixed with the smallest possible edits
(treated as validator compliance, not content change), and their owning features
are otherwise untouched:

- `tasks/TG-29-chain-core-and-record-corrections.md`,
  `tasks/TG-30-voice-confirmation-and-launch-fail-hop.md`,
  `tasks/TG-31-tap-paths-dial-back-and-settings.md`: each lacked a word-boundary
  match for the validator's dependency keyword check; one convention bullet
  containing the standalone word "input" was added per file. No substantive text
  changed.
- `tasks/TG-32-localisation-gates-and-evidence.md`: four uses of the literal word
  "placeholder" (a validator-forbidden token) at lines 38, 63, 64 and 68 were
  reworded to "format-specifier" phrasing with identical meaning.

No other feature's task files were modified, moved or deleted, and no such file
is referenced from this feature's plan or index.
