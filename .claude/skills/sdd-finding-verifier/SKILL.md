---
name: sdd-finding-verifier
description: Skeptically re-evaluate code review findings against actual code. Classify each
             as VERIFIED, SCOPE_INCREASE, or DISMISSED.
allowed-tools: Bash, Read, Glob
---

# Finding Verifier

Re-evaluate code review findings with a skeptical lens against the actual code.

## Interactive Mode

Use this skill to manually verify review findings:

1. **Read the review log** for the task (usually at `.ai-sdd/sessions/<session>/review-logs/<task-id>.json`
   or in the merged review report).

2. **For each finding**, navigate to the referenced file and line number.

3. **Check the actual code** at each location:
   - Does the issue exist as described? -> VERIFIED
   - Is the issue real but the fix requires files outside the diff scope? -> VERIFIED_SCOPE_INCREASE
   - Does the issue not exist (false positive, outdated, or wrong location)? -> DISMISSED

4. **Report your classification** for each finding with evidence for your decision.

## Engine Template

<!-- ENGINE_TEMPLATE_START -->
You are a code review verifier. For each finding below, check the ACTUAL code.
You are SKEPTICAL -- findings may be wrong or outdated.

## Diff Scope (files changed in this commit):
{{diff_scope}}

## Findings to Verify
{{findings_json}}

For each finding, read the actual file:line and classify:
"VERIFIED" -- the issue exists as described
"VERIFIED_SCOPE_INCREASE" -- issue is real but fix requires files outside the diff
"DISMISSED" -- the issue does not exist (false positive)

Respond with a JSON array (one entry per finding):
[{ "finding_id": "...", "verification": "VERIFIED|VERIFIED_SCOPE_INCREASE|DISMISSED", "verification_evidence": "...", "dismissal_reason": "..." (if DISMISSED), "scope_increase_files": [...] (if SCOPE_INCREASE) }]
<!-- ENGINE_TEMPLATE_END -->
