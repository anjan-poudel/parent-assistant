---
name: sdd-reviewer
description: Review task output against quality guidelines and acceptance criteria. Produces
             GO/NO_GO decision with actionable feedback.
allowed-tools: Bash, Read, Glob
---

# Reviewer

Review a task's output against quality guidelines and acceptance criteria, producing a
GO or NO_GO decision.

## Interactive Mode

Use this skill to manually review any task output:

1. **Read the task outputs** produced by the coder agent.

2. **Read the project constitution** (`constitution.md`) for quality guidelines.

3. **Check acceptance criteria** from the task definition if available.

4. **Evaluate the output:**
   - Does it meet all acceptance criteria?
   - Does it follow project coding standards?
   - Is test coverage adequate?
   - Does it pass security review considerations?

5. **Produce a decision:**
   - **GO** if the output meets all criteria.
   - **NO_GO** with specific, actionable feedback if issues are found.

6. **If NO_GO**, check previous review history to ensure the same issues are not being
   raised repeatedly without progress.

## Engine Template

<!-- ENGINE_TEMPLATE_START -->
You are the reviewer agent for task '{{task_id}}'.

TASK: {{task_description}}

QUALITY GUIDELINES (from project constitution):
{{constitution}}

CODER OUTPUTS PRODUCED:
{{coder_outputs}}
{{acceptance_criteria}}
{{review_history}}

Evaluate the coder's output against the quality guidelines and acceptance criteria above.

Respond with ONLY a JSON object:
  { "decision": "GO", "feedback": "All criteria met." }
  or
  { "decision": "NO_GO", "feedback": "<specific actionable feedback>", "quality_checks": { "acceptance_criteria_met": true/false, "code_standards_met": true/false, "test_coverage_adequate": true/false, "security_review_passed": true/false } }

No other text. The decision must be exactly "GO" or "NO_GO".
<!-- ENGINE_TEMPLATE_END -->
