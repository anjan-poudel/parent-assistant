---
name: sdd-hil
description: Manage human-in-the-loop (HIL) approvals — list, inspect, resolve, or reject
  pending items. Use when the workflow is paused waiting for human approval.
disable-model-invocation: false
allowed-tools: Bash
---
Manage HIL (human-in-the-loop) items for the ai-sdd workflow.

1. Run `ai-sdd hil list --json --project /Users/anjan/workspace/projects/ai/ai-sdd/ai-sdd-claude/examples/elderly-ai-assistant` to fetch pending items.

2. If no pending items, tell the user and stop.

3. For each pending item, display:
   - **ID** (shortened to first 8 chars for readability, show full ID in parentheses)
   - **Task**: the task_id that triggered the HIL gate
   - **Reason**: why human approval is needed
   - **Created**: timestamp

4. Ask the user what to do with each item:
   - **Show details**: `ai-sdd hil show <id> --project /Users/anjan/workspace/projects/ai/ai-sdd/ai-sdd-claude/examples/elderly-ai-assistant`
   - **Approve**: `ai-sdd hil resolve <id> --project /Users/anjan/workspace/projects/ai/ai-sdd/ai-sdd-claude/examples/elderly-ai-assistant`
     - Optionally add notes: `--notes "approval notes here"`
   - **Reject**: `ai-sdd hil reject <id> --reason "<reason>" --project /Users/anjan/workspace/projects/ai/ai-sdd/ai-sdd-claude/examples/elderly-ai-assistant`
   - **Skip**: move to the next item

5. After processing, run `ai-sdd hil list --json --project /Users/anjan/workspace/projects/ai/ai-sdd/ai-sdd-claude/examples/elderly-ai-assistant` again
   to confirm the queue is clear (or show remaining items).

Feature-scoped sessions: add `--feature <name>` after `hil` if working in a feature session.
Example: `ai-sdd hil --feature my-feature list --json --project /Users/anjan/workspace/projects/ai/ai-sdd/ai-sdd-claude/examples/elderly-ai-assistant`
