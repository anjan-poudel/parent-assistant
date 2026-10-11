# Implementation Tasks

Feature: **family-contacts-unify** (Family Contacts Unification)
Decomposition source: `specs/design-l2.md` rev 3. Total: 5 groups, 22 tasks, 0 subtasks, ~31 developer-days nominal.

| Group | Title | Tasks | Total Effort | Status |
|-------|-------|-------|-------------|--------|
| [TG-29](TG-29-sequencing-gate-and-identity-foundations/index.md) | Sequencing Gate and Identity Foundations | 4 tasks | ~4.5 days | PENDING |
| [TG-30](TG-30-contacts-access-link-verification-and-matching/index.md) | Contacts Access, Link Verification and Matching | 6 tasks | ~10.5 days | PENDING |
| [TG-31](TG-31-write-seam-and-coordinator-integration/index.md) | Write Seam and Coordinator Integration | 5 tasks | ~7.5 days | PENDING |
| [TG-32](TG-32-editor-and-call-surface-ui/index.md) | Editor and Call-Surface UI | 4 tasks | ~5 days | PENDING |
| [TG-33](TG-33-acceptance-evidence-and-device-validation/index.md) | Acceptance, Evidence and Device Validation | 3 tasks | ~3.5 days | PENDING |

## ID numbering

The task tree accumulates across features: the maximum before this plan was TG-28 / T-143, so this plan continues at **TG-29 / T-144**. Dependencies always point to strictly lower task IDs (ascending IDs form a valid topological order). This plan is leaf-task-only: no subtasks, because the ai-sdd unit planner dispatches every non-`index.md` file under `specs/plan-tasks/tasks/**` as a unit keyed by its leading `T-<digits>` token, and subtask files would collide with their parent task id.

## Dependency line format

Task files declare dependencies as a bare id first (machine-readable for the unit planner's dependency parser), followed by a relative link (human-readable) — e.g. [T-144](TG-29-sequencing-gate-and-identity-foundations/T-144-sequencing-gate-call-dialer-merge.md) (inside a task file the same link is written relative to its group folder). `- **Depends on**: —` means no dependencies.

## Preconditions

- No shared-surface work starts before [T-144](TG-29-sequencing-gate-and-identity-foundations/T-144-sequencing-gate-call-dialer-merge.md) verifies the call-dialer merge commit is on master and merges master into `feat/family-contacts-unify` (NFR-FCU-008).
- All work runs in the feature worktree `/Users/anjan/workspace/projects/elderly-ai-assistant-family-contacts-unify` (branch `feat/family-contacts-unify`).

## Top-level plan

- [plan.md](../plan.md) — summary, wave order, critical path, risks, security advisory mapping, requirement coverage
