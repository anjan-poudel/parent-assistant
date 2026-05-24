---
name: sdd-confidence-assessor
description: Assess task output quality and produce a confidence score (0.0-1.0). Used by the
             confidence overlay and available for manual quality checks.
allowed-tools: Bash, Read
---

# Confidence Assessor

Assess the quality of a task's output and produce a confidence score from 0.0 to 1.0.

## Interactive Mode

Use this skill to manually assess the quality of any task output:

1. **Identify the task** you want to assess (e.g. `design-l1`, `implement-auth`).
   Read its task definition to understand the expected deliverables.

2. **Read the task outputs** — the artifacts the task produced.

3. **Evaluate quality** against the project constitution and task acceptance criteria:
   - Completeness: Does the output cover all required aspects?
   - Correctness: Is the output technically sound?
   - Standards compliance: Does it follow project coding standards and conventions?
   - Documentation: Is it well-documented where required?

4. **Produce a score** from 0.0 (unacceptable) to 1.0 (perfect quality) with a brief
   justification for the rating.

## Engine Template

<!-- ENGINE_TEMPLATE_START -->
You are an evaluator agent assessing the quality of task '{{task_id}}'.
Task description: {{task_description}}

Task outputs produced:
{{task_outputs}}

Respond with ONLY a JSON object: { "score": <number 0.0 to 1.0> }
Where 1.0 = perfect quality, 0.0 = unacceptable. No other text.
<!-- ENGINE_TEMPLATE_END -->
