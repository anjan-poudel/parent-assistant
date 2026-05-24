---
name: sdd-debug
description: Diagnose ai-sdd workflow issues — checks config, session state, stuck tasks,
  HIL queue, stale locks, and log files. Use when the workflow is misbehaving.
disable-model-invocation: false
allowed-tools: Bash, Read, Glob
---
Diagnose ai-sdd workflow issues by running a series of health checks.

Run all of the following checks and then present a summary of findings:

## Check 1: Configuration
Run `ai-sdd validate-config --project /Users/anjan/workspace/projects/ai/ai-sdd/ai-sdd-claude/examples/elderly-ai-assistant`.
Flag any errors.

## Check 2: Current Session
Run `ai-sdd sessions list --json --project /Users/anjan/workspace/projects/ai/ai-sdd/ai-sdd-claude/examples/elderly-ai-assistant`.
Note which session is current (resolved from branch/env/feature).

## Check 3: Workflow Status
Run `ai-sdd status --json --project /Users/anjan/workspace/projects/ai/ai-sdd/ai-sdd-claude/examples/elderly-ai-assistant`.
Look for:
- Tasks stuck in RUNNING (may indicate a crashed agent)
- Tasks in NEEDS_REWORK that have hit max iterations
- Tasks in FAILED state
- Tasks in HIL_PENDING (need human action via `/sdd-hil`)

## Check 4: HIL Queue
Run `ai-sdd hil list --json --project /Users/anjan/workspace/projects/ai/ai-sdd/ai-sdd-claude/examples/elderly-ai-assistant`.
Flag any unresolved items — these block workflow progress.

## Check 5: Stale Engine Lock
Determine the current session name from `ai-sdd sessions list --json --project /Users/anjan/workspace/projects/ai/ai-sdd/ai-sdd-claude/examples/elderly-ai-assistant` (the `current` field).
Check if `/Users/anjan/workspace/projects/ai/ai-sdd/ai-sdd-claude/examples/elderly-ai-assistant/.ai-sdd/sessions/<current-session>/engine.pid` exists.
If it does, read the PID and check if that process is still running:
`ps -p <pid> > /dev/null 2>&1 && echo "running" || echo "stale"`
A stale PID file means the engine crashed. Safe to delete it.

## Check 6: Recent Logs
Determine the current session name from `ai-sdd sessions list --json --project /Users/anjan/workspace/projects/ai/ai-sdd/ai-sdd-claude/examples/elderly-ai-assistant`.
List log files in `/Users/anjan/workspace/projects/ai/ai-sdd/ai-sdd-claude/examples/elderly-ai-assistant/.ai-sdd/sessions/<current-session>/logs/`.
For any task that is stuck or failed, read the last 50 lines of its log file
to identify the error.

## Summary
Present findings as a checklist:
- Config: OK or list errors
- Session: which is active, task progress
- Blocked tasks: list any with reasons
- HIL items: count pending
- Engine lock: clean or stale
- Recommendations: specific next steps to unblock the workflow
