# TG-07: Smart-Mix Placement, Overlay Rendering and Toggle

> **Jira Epic:** Smart-Mix Placement, Overlay Rendering and Toggle

## Description

Renders every stable region in the active language: the four-condition in-place predicate and the
callout placement rules as one pure, unit-testable function (C11, D1, FR-LCT-015/016), the per-region
pending / resolved / degraded states with the accessibility standards (FR-LCT-018, NFR-LCT-003), and
the "always show original text" toggle that reduces the overlay to pure callout mode (FR-LCT-017).

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-020](T-020-overlay-placement.md) | `LiveOverlayPlacement` — in-place predicate and callouts (C11, D1) | L | T-001, T-002, T-009, T-010 | HIGH |
| [T-021](T-021-overlay-view-and-states.md) | Overlay view, states and accessibility | L | T-005, T-020 | HIGH |
| [T-022](T-022-always-show-original-toggle.md) | "Always show original text" toggle (FR-LCT-017) | M | T-001, T-020, T-021 | MEDIUM |

## Group effort estimate

- Optimistic (pure placement logic and view work overlap): 3–4 days
- Realistic (2 devs): 5–6.5 days
