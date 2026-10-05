# Implementation Tasks — Profile Interview (FR-PI v1)

| Group | Title | Tasks | Total Effort | Status |
|-------|-------|-------|-------------|--------|
| [TG-14](TG-14-profile-foundations/index.md) | Profile Foundations — store, guard, seams, strings | 4 | ~9.5–12 days | PENDING |
| [TG-15](TG-15-personalization-paths/index.md) | Personalization Paths — prompt clause, seed mirror, wake ack | 3 | ~9.5–12 days | PENDING |
| [TG-16](TG-16-interview-wizard-and-startup-routing/index.md) | Interview Wizard and Startup Routing | 6 | ~14.5–18 days | PENDING |
| [TG-17](TG-17-settings-release-and-evidence/index.md) | Settings, Log Safety and Release Evidence | 3 | ~8–10 days | PENDING |

**Totals:** 16 tasks (T-090 … T-105), all leaf tasks, ~41–52 developer-days sequential.

**ID numbering convention.** This plan continues after the accumulated global maxima: the highest
pre-existing task id is T-089 and the highest pre-existing group is TG-13 (computed before writing
via the prescribed scan over `specs/plan-tasks` plus the ai-sdd outputs). Profile Interview
therefore uses **T-090 … T-105** and **TG-14 … TG-17**; no existing T-NNN or TG-NN file or folder
was reused, overwritten or deleted. `specs/plan-tasks/plan.md` and this file are the two files the
established pattern replaces with the current feature's content.

Execution order is T-090 → T-105 in numeric order; every dependency points at a lower task ID, so a
subagent executing top-to-bottom never assumes an unbuilt component. The recommended parallel
packing is in the plan file (`## Summary` → recommended execution order).

Requirement IDs (FR-PI-NNN / NFR-PI-NNN) resolve under `specs/define-requirements/`; component IDs
(C01 … C13) and parameter names are used verbatim from `specs/design-l2.md`; amendment IDs
(AM-1 … AM-4) and finding IDs (SD-1 … SD-7) come from `specs/security-design-review.md`;
observation IDs (OB-1 … OB-5) come from `specs/review-l2.md`.
