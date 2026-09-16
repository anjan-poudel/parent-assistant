# Scaffold Report

**Mode:** brownfield-feature
**Feature:** live-camera-translation
**Scaffolded:** 2026-09-16 (worktree `live-camera-translation`, branch `worktree-live-camera-translation`)

## Files Created

- `specs/live-camera-translation/workflow.yaml` — feature workflow (canonical; loaded by `--feature live-camera-translation`)
- `.ai-sdd/workflows/live-camera-translation.yaml` — byte-identical mirror (loaded by `--workflow live-camera-translation`)
- `specs/live-camera-translation/constitution.md` — feature constitution (merged on top of the project constitution)
- `specs/live-camera-translation/init-report.md` — this report

## Feature Workflow

Task chain: `define-requirements` → `design-component` → `review-l2` (GO) →
`security-design-review` (SECURITY-GO) → `plan-tasks` → `implement` (paired review,
confidence 0.85) → `review-implementation` (GO) → `security-test` (SECURITY-GO) →
`final-sign-off` (T2 human gate).

The stock agile-feature template (T0/T1, no security tasks) was **not** used as-is: this feature
adds a camera permission and a new cloud egress path, so the workflow was hardened to the
project's existing safety-critical baseline. Rationale for each customisation is in the workflow's
header comment.

## Pre-existing Inputs

- `docs/superpowers/specs/2026-09-16-live-camera-translation-design.md` — owner-approved
  first-pass component design (the source of truth; its §10 Open Decisions and §11 divergences
  are carried into the feature constitution)
- `docs/superpowers/specs/2026-09-05-appliance-vision-helper-design.md` and
  `…-appliance-helper-live-ar-and-local-knowledge-addendum.md` §13 — the base design this feature
  inherits from
- `constitution.md` (project) — Architecture Constraint 1, Open Decision 12 (the recorded cloud
  voice-stack exception, which is the precedent shape for this feature's required amendment)

## Before Starting — Owner Actions

1. **The cloud translation tier needs a recorded exception amendment** (project constitution,
   Open Decisions, Open Decision 12 shape) before the feature is shippable. The constraint is
   enforced by the `final-sign-off` gate; draft the wording in the OD-12 review window
   (2026-10-13).
2. **State layout note:** this project still uses the legacy flat `.ai-sdd/state/` layout, so a
   feature session shares `.ai-sdd/state/workflow-state.json` with the completed project
   workflow. If the feature workflow will be run from this project (rather than a throwaway
   worktree), consider migrating to the runs layout (`ai-sdd init --tool claude_code`) first so
   each session gets `.ai-sdd/runs/<feature>/`.

## Next Steps

1. Review `specs/live-camera-translation/constitution.md` — resolve or accept the Open Decisions.
2. `ai-sdd validate-workflow --feature live-camera-translation` (passes as scaffolded).
3. Run the workflow with `--feature live-camera-translation` (or `--workflow live-camera-translation`).
