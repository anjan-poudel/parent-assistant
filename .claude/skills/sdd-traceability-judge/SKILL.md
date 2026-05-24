---
name: sdd-traceability-judge
description: Evaluate whether task outputs stay within requirements scope. Used automatically
             by the traceability overlay and available for manual spot-checks.
allowed-tools: Bash, Read
---

# Traceability Judge

Evaluate whether a task's outputs stay within the scope of locked requirements.

## Interactive Mode

Use this skill to manually verify traceability for any task:

1. **Read the requirements lock file** at `specs/define-requirements.lock.yaml`.
   If it does not exist, traceability evaluation cannot proceed.

2. **Identify the task** you want to evaluate (e.g. `design-l1`, `implement-auth`).
   Read its task definition from the workflow to understand its declared scope.

3. **Read the task outputs** — the artifacts the task produced (e.g. `specs/design-l1.md`).

4. **Compare outputs against requirements:**
   - Does the output address ONLY topics covered by the locked requirements?
   - Does it introduce features, components, or decisions not traceable to any requirement?

5. **Report findings** — list any out-of-scope elements with specific references to
   which part of the output is not traceable to which requirement.

## Engine Template

<!-- ENGINE_TEMPLATE_START -->
You are a traceability evaluator. Given:
1. Requirements lock (the approved requirements for this project)
2. Task output (the artifact produced by this task)

Determine whether the task output stays within the scope of the locked requirements.
- "in_scope": true if output addresses ONLY topics covered by the requirements
- "in_scope": false if output introduces features, components, or decisions not traceable to any requirement

Requirements lock:
{{lock_content}}

Task: {{task_id}} — {{task_description}}
Task outputs:
{{task_outputs}}

Respond with ONLY a JSON object: { "in_scope": true/false, "findings": ["..."] }
<!-- ENGINE_TEMPLATE_END -->
