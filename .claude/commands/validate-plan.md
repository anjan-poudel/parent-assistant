# /validate-plan

Triggers the **plan-validator** skill. Validates every task in a plan before
any code is written. Does not implement — use `/tdd-exec` after validation passes.

## Usage

```
/validate-plan
```
Validates the current plan from context.

```
/validate-plan --from plan.md
```
Load tasks from a markdown file (numbered list or `- [ ] ...` checkboxes).

```
/validate-plan --task "POST /login returns 200 with JWT on valid credentials"
```
Validate a single task description.

## What happens

1. Displays a numbered task summary
2. For each task: runs 7 checks (scope, vagueness, testability, blast radius,
   dependencies, acceptance criterion, reversibility)
3. Shows a report card per task — proposes fixes for failures, asks for approval
4. Re-validates until all tasks pass
5. Runs plan-level checks: ordering, coverage, rollback safety
6. Signals readiness: "→ run `/tdd-exec` to implement"

## Flags

| Flag | Effect |
|---|---|
| `--from <file>` | Load tasks from a markdown plan file |
| `--task <text>` | Validate a single task inline |
| `--batch <n>` | Validate in batches of N (default: all) |
