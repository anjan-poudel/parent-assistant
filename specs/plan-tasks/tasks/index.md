# Implementation Tasks

| Group | Title | Tasks | Total Effort | Status |
|-------|-------|-------|-------------|--------|
| [TG-24](TG-24-dialogue-frame-foundations/index.md) | Dialogue Frame Foundations | 5 tasks | ~6.5 days | PENDING |
| [TG-25](TG-25-answer-classification-and-merge/index.md) | Answer Classification and Merge | 3 tasks | ~7.5 days | PENDING |
| [TG-26](TG-26-router-interception-and-window-state/index.md) | Router Interception and Window State | 4 tasks | ~14.5 days | PENDING |
| [TG-27](TG-27-observability-release-gate-and-security-evidence/index.md) | Observability, Release Gate and Security Evidence | 4 tasks | ~7.5 days | PENDING |
| [TG-28](TG-28-acceptance-evidence-and-device-protocol/index.md) | Acceptance, Evidence and Device Protocol | 3 tasks | ~5 days | PENDING |

**Totals:** 5 groups, 19 tasks (0 subtasks), ~41 developer-days nominal.
**Critical path:** T-130 → T-131 → T-133 → T-136 → T-139 → T-141 → T-142 (23 days).
Full plan with the wave table and requirement map: [plan.md](../plan.md).

## Wave order (file-disjoint)

- W1: T-125, T-126, T-127, T-128, T-129, T-130, T-135, T-137
- W2: T-131, T-132
- W3: T-133, T-138
- W4: T-134, T-136
- W5: T-139, T-140, T-143
- W6: T-141
- W7: T-142

## ID numbering convention

This tree accumulates across features: group folders and task files from earlier
features remain on disk, and a new feature continues at the global maxima. Previously
delivered groups visible in this directory: TG-01..TG-10 (T-001..T-030,
live-camera-translation), TG-14..TG-17 (T-090..T-105, profile-interview) and
TG-18..TG-23 (T-106..T-124, spotify-music-integration). This feature uses
**TG-24..TG-28 and T-125..T-143**; the next feature continues at **TG-29 / T-144**.

Dependencies point at lower task IDs only, so ascending ID order is a valid topological
order for the `implement` workflow's wave sort.

## Requirement ID resolution

Requirement links in task files climb four directory levels to
`define-requirements/FR/...` and `define-requirements/NFR/...`, which resolve to
`specs/define-requirements/` in this worktree. All 20 FR-MTC and 12 NFR-MTC documents
are linked from at least one task; the per-requirement map is in
[plan.md](../plan.md).
