---
name: sdd-parallel-review
description: Focused code review for a specific area (type-safety, security, performance, etc.).
             Produces structured findings with file, line, tier, priority.
allowed-tools: Bash, Read, Glob
---

# Parallel Review (Focused)

Perform a focused code review for a specific area, producing structured findings.

## Interactive Mode

Use this skill to manually run a focused code review:

1. **Choose your focus area** (e.g. type-safety, security, performance, error-handling).

2. **Read the task outputs** — the code and artifacts to review.

3. **Review ONLY your focus area** — do not flag issues outside your designated concern.

4. **For each finding**, specify:
   - File path and line number
   - Tier (1 = correctness/must-fix, 2 = cleanliness/should-fix)
   - Priority (P1 = critical, P2 = important, P3 = minor)
   - Category matching your focus area
   - Description of the issue
   - Suggested fix
   - Whether fixing it would increase scope beyond the current diff

5. **Report findings** as a structured JSON array. An empty array is valid if no issues found.

## Engine Template

<!-- ENGINE_TEMPLATE_START -->
You are a specialized code reviewer focused on: {{focus_upper}}

TASK: {{task_description}}

YOUR REVIEW FOCUS: {{focus}}
YOUR CHECKLIST (check ONLY these items -- do not evaluate other concerns):
{{checklist}}

CODER OUTPUTS:
{{coder_outputs}}
{{acceptance_criteria}}

INSTRUCTIONS:
  - Review ONLY the items in your checklist above.
  - Do NOT flag issues outside your focus area.
  - For each finding, specify file path, line number, tier, priority, category, description.
  - Tier 1 = correctness issues (must fix), Tier 2 = cleanliness issues (should fix).
  - Priority: P1 = critical, P2 = important, P3 = minor.

Respond with ONLY a JSON object:
{
  "findings": [
    {
      "file": "src/example.ts",
      "line": 42,
      "tier": 1,
      "priority": "P1",
      "category": "type-safety",
      "description": "Unsafe cast from unknown to string",
      "suggested_fix": "Use type guard or assertion with validation",
      "scope_increase": false
    }
  ]
}

Empty array is valid if no issues found. No other text.
<!-- ENGINE_TEMPLATE_END -->
