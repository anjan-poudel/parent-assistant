# Amendment 4 — Wave-end testing and batched unit closure (2026-10-14)

Status: **applied**. Source: owner directive relayed by the main session mid-run on
2026-10-14. Supersedes the per-unit test cadence used in Waves 0–1 of `implement`.

## The directive (as received)

- Move testing to the END of each wave: **no per-unit xcodebuild test runs**.
- Per-unit work = **code + build/typecheck only** (no test execution, no per-unit
  test gate).
- At each wave close: **ONE consolidated typecheck + focused-test pass** over the
  wave's touched suites, scoped (`-only-testing`), per the honest-gate baseline
  rule.
- The **single full-suite pass at the very end** and the **hard safety gates**
  (T-181/T-182 training eval gates; emergency recall 1.00, abstention ≥ 0.90,
  closed-intent ≥ 0.95) are **unchanged**.
- Companion change: batch per-unit closure artifacts (evidence records + commits)
  to **one commit per wave** where the engine permits.

## Cutover

- The three in-flight Wave-2 agents (T-176, T-179, T-181) finish under the old
  cadence — no mid-unit interruption, per the directive.
- Wave-2's not-yet-dispatched units (T-170, T-175) are dispatched under the NEW
  cadence: they had not started when the directive arrived, so the directive's
  operative rule (no per-unit test execution) governs them; the Wave-2 close
  consolidated pass covers their suites.
- This amendment, the `plan.md` execution-mode note and the workflow-config
  comment ride the Wave-2 close commit (the "next wave" commit).
- No change is retroactive: Wave 1 (closed pre-directive) used the old cadence and
  its gate stands as recorded.

## What changes in this worktree's coordination practice

- **Per unit:** the agent builds/typechecks its touched target(s) (iOS: a build or
  targeted `swiftc -typecheck`; Python: `py_compile` / import check) and authors
  its tests in-unit, but does **not** execute the unit's suite — nor cross-check
  suites — at unit time. The unit's tests are AUTHORED, then EXECUTED at the wave
  close.
- **Per wave close (coordinator):** ONE consolidated pass — a single scoped iOS
  invocation over the wave's touched suites (`./build.sh test:unit <Suite…>`, which
  accepts multiple class names in one invocation) plus a single scoped Python
  `unittest` invocation over the wave's touched modules — then the batched unit
  evidence records (`complete-task --unit`, per unit, one write each) and the
  single wave commit.
- **Unchanged:** the phase-close gate, the single full-suite pass at the very end
  (owner rule of 2026-09-28), the T-181/T-182 hard training-eval gates, the
  honest-gate scoped-run baseline rule, and the DV-1..DV-6 device protocol.
- **Test authoring discipline still binds in-unit:** a unit's Definition of Done
  includes its tests being written and the suite existing; only the *execution*
  moves to the wave close.

## Engine constraints recorded (as reported to the coordinator)

1. **No engine knob exists for test cadence.** `implement.unit_execution` carries
   `plan_task_id` (plus the waves-default comment) only; unit-completed evidence
   records carry `gates_required: []`; the engine's enforced gates are the
   phase-close guard and the workflow task-level gates. This amended cadence is a
   coordinator convention, recorded here and in the workflow-config comment — not
   an engine-enforced switch. (The per-unit test runs in Waves 0–1 were wave
   discipline, not an engine gate — relaxing them cannot relax any engine gate.)
2. **Evidence records are atomic per unit** (one `unit-completed` record per
   `complete-task --unit` invocation). Records are batched to the wave close as in
   Waves 0–1, but cannot be merged into a single record.
3. **Commits were already one-per-wave** in Waves 0–1 (no per-unit commits exist on
   the branch); the companion change is already satisfied and continues.
4. **Run-targeting gotcha (hit in Wave 1):** a bare `complete-task` resolves run
   `default` (the legacy run state); the feature run requires
   `--feature conversational-nepali-replies`. Three Wave-1 records were
   mis-targeted and re-recorded under the correct run; the append-only stream
   keeps the mis-targeted seq 170–172 as documented duplicates (Wave-1 commit).
5. **Content sanitizer:** a full 64-hex sha256 string in the submitted
   `specs/implement-notes.md` trips the `base64_payload` injection heuristic
   (`complete-task` refuses; the transitory NEEDS_REWORK message left no persisted
   state change). House style is the shortened hash form (`83283663…fcb1519`);
   full hashes live in the unit notes files.
