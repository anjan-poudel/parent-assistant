---
name: sdd-run
description: Run the ai-sdd SDD workflow. Spawns the correct agent for the active task,
             handles HIL approvals inline, and loops. Use this to drive the full workflow.
disable-model-invocation: false
context: fork
allowed-tools: Bash, Task
---
Run the ai-sdd SDD workflow. If you're on a feature branch, ai-sdd uses it.
Otherwise pass `--feature <name>` or set `AI_SDD_FEATURE` in the environment.
To switch sessions: `git switch feature/<name>` (session follows the branch).

Follow these steps:

1. Pre-flight: run `ai-sdd health --project {{PROJECT_PATH}}` via Bash and show the
   summary (exit code 1 simply means findings were reported — show them and continue;
   exit code 2 means the scan could not run — surface the error). This step is
   report-only: list the findings, then move on. Do not block, wait for a developer
   decision, attempt any repair, or modify any state, evidence, or manifest file. In
   CI the pre-flight runs without any interactive step.

2. Run `ai-sdd status --next --json --project {{PROJECT_PATH}}` via Bash to find the
   next READY task (PENDING with all dependencies COMPLETED) and its agent role.

   If `ready_tasks` is empty, check overall status with
   `ai-sdd status --json --project {{PROJECT_PATH}}` — the workflow may be complete
   or all remaining tasks may be blocked.

3. Spawn the matching subagent using the Task tool based on the task's `agent` field.
   The agent field is the source of truth — do not hardcode task-name → agent mappings.
   Map agent names to subagents:
   - ba        → Task(sdd-ba)
   - architect → Task(sdd-architect)
   - pe        → Task(sdd-pe)
   - le        → Task(sdd-le)
   - dev       → Task(sdd-dev)
   - reviewer  → Task(sdd-reviewer)

   If multiple tasks are READY simultaneously, spawn them sequentially one at a
   time and collect all results before continuing — unless the READY task is
   `implement`, which is fanned out as described in "Fan-out on `implement`" below.

4. After the subagent returns, run `ai-sdd hil list --json --project {{PROJECT_PATH}}`.
   If any PENDING HIL items:
   - Show the item context to the developer.
   - Ask: "Approve to continue? [yes/no]"
   - On yes: run `ai-sdd hil resolve <id> --project {{PROJECT_PATH}}`.
   - On no:  run `ai-sdd hil reject <id> --reason "<reason>" --project {{PROJECT_PATH}}`.
   Configuration key: when the session's messaging plugin config sets
   `slack.answers_only: true`, the terminal refuses the two commands above —
   HIL decisions settle only from Slack. Apply the operator's stated Slack
   decision (the gate post's buttons or the operator's channel reply) with the
   from-slack provenance flag instead, and never fabricate an approval:
   - On yes: run `ai-sdd hil resolve <id> --project {{PROJECT_PATH}} --from slack`.
   - On no:  run `ai-sdd hil reject <id> --reason "<reason>" --project {{PROJECT_PATH}} --from slack`.
   Never run a flagless `hil resolve` / `hil reject` while `slack.answers_only`
   is active — the CLI refuses it and the gate stays open. Without the knob,
   the forms above apply unchanged.

5. Run `ai-sdd status --metrics --project {{PROJECT_PATH}}` and show the updated table.

6. Ask the developer: "Continue to next task? [yes/no/done]"
   When the session's messaging plugin is configured (`@ai-sdd/messaging` in
   `.ai-sdd/ai-sdd.yaml`), mirror the gate to the session's Slack channel and
   use the Slack answer as the developer's answer: run
   `ai-sdd messaging ask --question "Continue to next task?" --options yes,no,done --wait --project {{PROJECT_PATH}}`
   via Bash. On exit 0, the single stdout line is the answer — use it as the
   choice below. On exit 3 (no answer: expired or interrupted) or any other
   non-zero exit, ignore stdout and ask the developer directly as below.
   Without `--wait` the command is non-blocking: it prints the question id and
   returns immediately, and you can resolve it later from the terminal with
   `ai-sdd messaging answer <question-id> <choice>` — first answer wins between
   Slack and the terminal, so a late answer on either side is ignored.
   With `slack.answers_only: true`, the terminal `ai-sdd messaging answer`
   form above is refused — answer from the Slack channel only (tap an option
   or reply in the thread). Keep `--wait`: the wait horizon is effectively
   forever under the knob, so exit 3 means the operator interrupted — re-post
   the question with the same command instead of asking in the terminal.
   - yes  → repeat from step 2
   - no   → stop and show final status
   - done → workflow complete

---

## Fan-out on `implement`

`implement` is unit-based: one task, many units. It is the one task where the
coordinator may run units concurrently instead of sequentially.

### Deciding the wave

Before spawning anything, read the plan:

1. Read `specs/<plan_task_id>/plan.md` and note the **phase table** — units are
   grouped into phases, and phases are ordered.
2. Read each unit's `Depends on:` line in `specs/<plan_task_id>/tasks/<unit>.md`
   and the files each unit declares (backticked paths in its spec).

Two units may run in the same wave only when they are in the **same phase**,
neither depends on the other, and their declared files are **disjoint**. When in
doubt, serialize — a wrong wave costs a rework cycle, a right serialization costs
one dispatch.

Never put two units that each rewrite the same generated catalogue or re-count the
same corpus in one wave (e.g. two copy-catalogue units, or two census-test units).
They contend on the same shared files and counts; run them in separate waves and
let the coordinator re-pin the counts between them.

### Spawning

Spawn **2–3 `Task(sdd-dev)` agents in a single message** so they run concurrently —
one message with multiple Task calls, not one message per unit. Give each agent the
wave execution contract:

- implement this unit only — code and tests within its declared files;
- do **not** run the project-wide test suite (the coordinator runs it; a shared
  suite result taken while a sibling is still writing is meaningless);
- do **not** create git commits;
- do **not** run `ai-sdd complete-task` or otherwise mark the unit complete.

### Integrating (the coordinator is the single writer)

Units return reports; the coordinator does everything shared, serially:

1. Integrate the returned work into the working tree, one unit at a time.
2. **Re-pin shared counts** — any census, catalogue index or aggregate fixture the
   fanned-out units touched must be recomputed and pinned by the coordinator, in
   the integration order, after all wave units have landed. Never accept a count a
   subagent wrote while a sibling was still editing the same corpus.
3. Run **per-unit targeted tests** — only the test files that unit touches, never
   the full suite per unit.
4. Run the phase gate once, at the end of the phase, over the integrated tree.
5. Only then complete `implement` for that phase, and move to the next phase.

### Engine-native parallel path supersedes this

The fan-out above is the coordinator-side, manual version of an execution mode the
engine implements directly. When a workflow declares it —

```yaml
unit_execution:
  parallelism: sequential   # opt-out — absent means "waves" (the default)
  max_parallel_units: 3     # default 3
  final_units: [T-090]      # units that must run strictly last
  commit_per_wave: false    # default false
```

— the engine itself plans the waves from the same `Depends on:` declarations and
file ownership, dispatches the units concurrently, keeps the single-writer rules
(gates and commits stay with the orchestrator), and attributes shared-suite
failures to the owning unit. Waves are the default when `parallelism` is absent.
For an engine-driven run do **not** fan out by hand on top of it: follow
`status --next` as usual and let the wave runner do the scheduling. The manual
fan-out in this skill is for runs where `implement` is explicitly declared
`parallelism: sequential` and the coordinator drives it directly.
