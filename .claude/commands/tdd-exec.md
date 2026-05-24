# /tdd-exec

Triggers the **tdd-executor** skill. Implements a validated plan one task at a
time using strict TDD: red → green → refactor → commit → next task.

Run this after `/validate-plan` has confirmed all tasks pass.

## Usage

```
/tdd-exec
```
Implements the validated plan from context, task by task.

```
/tdd-exec --task "POST /login returns 200 with JWT on valid credentials"
```
Run TDD on a single task.

```
/tdd-exec --from plan.md
```
Load and implement tasks from a markdown file.

## What happens

For each task:
1. 🔴 **RED** — writes a failing test that expresses the acceptance criterion; confirms it fails
2. 🟢 **GREEN** — implements the minimum code to make the test pass; confirms it passes
3. 🔵 **REFACTOR** — cleans up if needed; confirms tests still pass
4. ✅ **COMMIT** — shows commit message suggestion, waits for confirmation before next task

Never writes implementation code before a failing test exists.
Never moves to the next task while any test is failing.

## Flags

| Flag | Effect |
|---|---|
| `--task <text>` | Run TDD on a single task |
| `--from <file>` | Load tasks from a markdown plan file |
| `--start-at <n>` | Resume from task N (e.g. after interruption) |
| `--no-confirm` | Skip per-task confirmation prompts (use with care) |
