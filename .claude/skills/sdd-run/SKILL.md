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

Project resolution: the CLI defaults `--project` to the current working
directory — invoke from the repo root or the active worktree and do NOT pass
`--project` unless the user asks. Pass `--feature <name>` on the default
branch; on a feature branch the session follows the branch name.

Follow these steps:

1. Run `ai-sdd status --next --json` via Bash to find the
   next READY task (PENDING with all dependencies COMPLETED) and its agent role.

   If `ready_tasks` is empty, check overall status with
   `ai-sdd status --json` — the workflow may be complete
   or all remaining tasks may be blocked.

2. Spawn the matching subagent using the Task tool based on the task's `agent` field.
   The agent field is the source of truth — do not hardcode task-name → agent mappings.
   Map agent names to subagents:
   - ba        → Task(sdd-ba)
   - architect → Task(sdd-architect)
   - pe        → Task(sdd-pe)
   - le        → Task(sdd-le)
   - dev       → Task(sdd-dev)
   - reviewer  → Task(sdd-reviewer)

   If multiple tasks are READY simultaneously, spawn them sequentially one at a
   time and collect all results before continuing.

3. After the subagent returns, run `ai-sdd hil list --json`.
   If any PENDING HIL items:
   - Show the item context to the developer.
   - Ask: "Approve to continue? [yes/no]"
   - On yes: run `ai-sdd hil resolve <id>`.
   - On no:  run `ai-sdd hil reject <id> --reason "<reason>"`.

4. Run `ai-sdd status --metrics` and show the updated table.

5. Ask the developer: "Continue to next task? [yes/no/done]"
   - yes  → repeat from step 1
   - no   → stop and show final status
   - done → workflow complete
