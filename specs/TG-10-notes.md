# TG-10 — Continuous Learning Loop: implementation notes

**Task:** plan-tree authoring (documentation only) — design doc, task group and plan/index updates for the continuous learning loop.
**Worktree:** `.claude/worktrees/tg10-continuous-learning` (branch `worktree-tg10-continuous-learning`, base `5a908ac4ef6a`).
**Scope discipline:** no production code, no builds, no tests, no simulator, no merge, no push. Every artifact below is Markdown.

## What was built

1. **Design doc** — `docs/superpowers/specs/2026-09-13-continuous-learning-loop-design.md`. Five-stage loop (CAPTURE → MINE → AUGMENT → RETRAIN → SHADOW/HEAL), a "Recorded decisions" section carrying D-1 (opt-in), D-2 (hashed-only egress), D-3 (weekly retrain cadence) and D-4 (human publish gate), a ground-truth table of ~30 file:line citations read before writing, a "What leaves and what never leaves" section with the per-field egress table, the promotion rule, boundaries/invariants, options weighed, out-of-scope, requirements traceability, task mapping, and the literal `## Risks and mitigations` (R-1…R-9) and `## Open questions` sections (OQ-1…OQ-4). House style follows `2026-09-13-joint-intent-slot-encoder-design.md` and `2026-09-13-encoder-training-data-strategy.md`.
2. **Task group TG-10** — `.ai-sdd/outputs/plan-tasks/tasks/TG-10-continuous-learning-loop/` with `index.md` (mirroring TG-09's index format: Epic line, Description incl. the TG-08 reconciliation and the boundary the group does not cross, Tasks table, group effort estimate) and one file per task, each with the five sections (Metadata, Description, Acceptance criteria, Implementation notes, Definition of done), exactly one Gherkin `Feature:`/`Scenario:` block, a `- **Requirements:**` line, and cross-references that resolve.
3. **Plan/index updates** — `plan.md` (header counts, critical-path bullet for TG-10, TG-03 count, Task Group Summary row + total, traceability rows), `tasks/index.md` (TG-03 row, new TG-10 row).

| ID | Title | Effort | Risk |
|----|-------|--------|------|
| T-052 | Continuous-Learning Signal Quality — Feasibility (R&D) | S | MEDIUM |
| T-053 | Learning-Loop Privacy Review (R&D) | S | MEDIUM |
| T-054 | Capture Schema & Egress Contract Design | M | HIGH |
| T-055 | Shadow Scoring & Healing Protocol Design | M | HIGH |
| T-056 | Capture & Egress Implementation (opt-in) | L | HIGH |
| T-057 | Correction Miner Implementation | M | MEDIUM |
| T-058 | Promotion Gate Implementation | M | HIGH |
| T-059 | Privacy Audit (verification) | M | HIGH |
| T-060 | Loop End-to-End Fixture (verification) | M | MEDIUM |

Group effort estimate (in `TG-10-continuous-learning-loop/index.md`): optimistic 22–34 days, realistic 28–45 days; entry gate none hard.

## Decisions made during implementation

- **Task IDs are T-052–T-060, not T-051–T-059.** The brief assumed T-051 was free; it was not. `T-051-gemma-template-and-general-purpose-framing.md` already exists in TG-03 (added by `8b0e9a0`, with its own row in the TG-03 index), so the whole group shifted by one, keeping the brief's phase order and titles exactly. Slug and directory: `TG-10-continuous-learning-loop`. Commit message therefore reads `[TG-10] Continuous Learning Loop design doc + task group (T-052–T-060)`.
- **Counts were recounted from disk, not propagated.** `plan.md`'s header claimed 39 parent tasks / 50 IDs (T-001–T-050), which already omitted T-051. The verified numbers now in the file are 49 parent tasks across 60 IDs (T-001–T-060), 10 task groups; the Task Group Summary total row and the TG-03 row were corrected to match. No task ID was renamed or reused.
- **TG-10 is explicitly off the critical path.** The header bullet and the risk section both say the group adds nothing to `T-033 → T-034 → T-035 → T-036 → T-037 → T-038`; T-058 consumes the T-038 harness as-is and a needed harness output is a T-038 change request, not a fork.
- **The `IntentLogStore` tension is reconciled by design, not by ignoring it.** The shipped docstring says the log "leaves only via the family's explicit export" (`IntentLogStore.swift:8-14`). The loop's egress is designed as a *separate* channel over derived signal only, and T-056 carries an explicit Definition-of-done item to amend the docstring so the shipped source describes both channels. The docstring was not quietly re-interpreted.
- **Egress is not the observability bus.** `ConsoleObservabilityBus` prints; the loop's egress is a distinct opt-in uploader, which is why the design has a "why not the observability bus" subsection and why T-059 audits loop telemetry in addition to the capture payload.
- **Risk numbering** in `plan.md` continues the existing list (items 30 and 31), and the TG-10 paragraph in "Security blockers" follows the existing "No new security BLOCKERs are introduced by X" pattern. Both were appended, not inserted mid-list.
- **Headings** `## Risks and mitigations` and `## Open questions` are literal and unnumbered so they match the brief's requirement while the numbered sections around them stay house-style.

## Verification performed (documentation-only)

- **Link resolution.** A script checked every Markdown link in the 14 touched/created files against the filesystem: all links written by this task resolve. Two broken links exist in `tasks/index.md` **pre-existing and untouched** (`../TG-02-voice-interface/T-049-…` and `../TG-01-foundation-infrastructure/T-050-…` — one `..` too many for that file's depth; the real paths are `TG-02-voice-interface/…`, `TG-01-foundation-infrastructure/…`). Left as-is to keep the diff minimal; reported as an observation.
- **Evidence check.** Every `file:line` citation in the design doc and the task files was read against the worktree before writing; T-051's `Requirements` line was re-read (`FR-007, FR-008`) before its traceability row was added to `plan.md`.
- **Count check.** Task files on disk per group were counted, not inferred: TG-03 = 8 (T-018, T-020, T-021, T-045…T-048, T-051); TG-10 = 9 (T-052…T-060).
- **Secret/PII scan.** Regex sweep over all deliverables for 40-character SHAs, 13–39-character hex runs, e-mail addresses, 7+ digit runs and credential-shaped `key=value` patterns: no hits except the word "secret" inside T-060's own prohibition prose and a pre-existing 7-character commit prefix in `plan.md`. All SHAs written by this task are 12-character prefixes; the only credential-shaped token used is the sentinel `SENTINEL_API_KEY`.
- **No build/test/simulator command was run** — out of scope for this documentation task, and the constraint was explicit.

## Open questions (carried into the task files, not silently resolved)

- **OQ-1** — whether the loop needs its own disclosure under Open Decision 12 or an amendment to OD-12 itself.
- **OQ-2** — whether the family's export consent covers mined rows transiting the cloud teacher in `gen_teacher.py`; T-057 may not feed the teacher until T-053 rules.
- **OQ-3** — the retention window for the salted signal record.
- **OQ-4** — what "the incumbent" is when the household runs the cloud engine rather than the on-device encoder; T-058 must define it per configuration.
- **Stale estimate outside this task's scope** — `TG-03-on-device-ai/index.md`'s "Group effort estimate" (17–27 days realistic) was not updated when T-051 was added, and `tasks/index.md` mirrors that number. This task fixed the *counts and ID lists* but did not invent a new day range for someone else's group; the group index is the right place to revise it.
- **Stale line 15 note links** in `tasks/index.md` (see above) — pre-existing, reported, untouched.
