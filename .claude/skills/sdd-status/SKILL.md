---
name: sdd-status
description: Show the current ai-sdd workflow progress and cost summary
allowed-tools: Bash
---
Run `ai-sdd status --metrics --project /Users/anjan/workspace/projects/ai/ai-sdd/ai-sdd-claude/examples/elderly-ai-assistant` and display the results
as a formatted table. Highlight any FAILED or HIL_PENDING tasks.

The current session is resolved automatically (flag → env → branch → auto).
To check sessions: `ai-sdd sessions list --project /Users/anjan/workspace/projects/ai/ai-sdd/ai-sdd-claude/examples/elderly-ai-assistant`
