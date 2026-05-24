---
name: sdd-pre-review
description: Holistic pre-review analysis -- detect unrelated changes, removed export impact,
             and new concepts before the main review cycle.
allowed-tools: Bash, Read, Glob
---

# Pre-Review Analyzer

Perform a holistic pre-review analysis before the main review cycle begins.

## Interactive Mode

Use this skill to manually run a pre-review analysis for any task:

1. **Identify the task** you want to analyze (e.g. `implement-auth`).
   Read its task definition to understand the declared scope and expected output paths.

2. **Read the task outputs** — the artifacts and code the task produced.

3. **Run the three analysis checks:**

   a. **Unrelated Changes Check** — Identify any files that appear to have been modified
      but are NOT part of the task's declared scope. Consider the task outputs list,
      the task description, and the constitution standards.

   b. **Removed Export Impact Check** — Identify any exported symbols (functions, classes,
      interfaces, constants) that were removed or renamed. For each, list any usages you
      can identify that may be affected outside the changed files.

   c. **New Concept Inventory** — List new domain terms, interfaces, enums, or abstractions
      introduced by this implementation. Note whether each is expected by the task
      specification or constitution.

4. **Report findings** in structured format with arrays for each category.

## Engine Template

<!-- ENGINE_TEMPLATE_START -->
You are performing a holistic PRE-REVIEW analysis for task '{{task_id}}'.

TASK: {{task_description}}
EXPECTED OUTPUT PATHS: {{expected_output_paths}}

ACTUAL OUTPUTS PRODUCED:
{{actual_outputs}}

ANALYSIS REQUIRED:

1. UNRELATED CHANGES CHECK
   Identify any files that appear to have been modified but are NOT part of the task's declared scope.
   Consider: the task outputs list, the task description, the constitution standards.

2. REMOVED EXPORT IMPACT CHECK
   Identify any exported symbols (functions, classes, interfaces, constants) that were removed or renamed.
   For each, list any usages you can identify that may be affected outside the changed files.

3. NEW CONCEPT INVENTORY
   List new domain terms, interfaces, enums, or abstractions introduced by this implementation.
   Note whether each is expected by the task specification or constitution.

Respond with ONLY a JSON object in this exact format:
{
  "unrelated_changes": ["file/path.ts", ...],
  "removed_exports_impact": [
    { "symbol": "MyFunction", "usages": ["src/other.ts:42", ...] }
  ],
  "new_concepts": ["ConceptName: brief explanation", ...]
}

No other text. Empty arrays are valid if no issues found.
<!-- ENGINE_TEMPLATE_END -->
