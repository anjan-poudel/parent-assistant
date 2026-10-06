# Implementation Tasks

| Group | Title | Tasks | Total Effort | Status |
|-------|-------|-------|-------------|--------|
| [TG-18](TG-18-spotify-tool-and-deep-link-hardening/index.md) | Spotify Tool and Deep-Link Hardening | 2 tasks | ~5.5 days | PENDING |
| [TG-19](TG-19-account-linking-credential-store-and-session/index.md) | Account Linking, Credential Store and Session | 4 tasks | ~11 days | PENDING |
| [TG-20](TG-20-music-intent-intake-and-contact-veto/index.md) | Music Intent Intake and Contact Veto | 2 tasks | ~3.5 days | PENDING |
| [TG-21](TG-21-router-music-path-degradation-and-tool-log/index.md) | Router Music Path, Degradation and Tool Log | 3 tasks | ~8 days | PENDING |
| [TG-22](TG-22-plugin-wiring-settings-and-localisation/index.md) | Plugin, Wiring, Settings and Localisation | 4 tasks | ~9.5 days | PENDING |
| [TG-23](TG-23-release-gates-security-evidence-and-device-validation/index.md) | Release Gates, Security Evidence and Device Validation | 4 tasks | ~8 days | PENDING |

**Totals:** 6 groups, 19 tasks, 0 subtasks, ~45.5 developer-days nominal.

## ID numbering convention

This tree accumulates across features: group folders and task files from earlier features
remain on disk, and a new feature continues at the global maxima — **TG-18** and
**T-106**. Previously delivered groups visible in this directory: TG-01..TG-10
(T-001..T-030, live-camera-translation) and TG-14..TG-17 (T-090..T-105,
profile-interview). This feature uses TG-18..TG-23 and T-106..T-124; the next feature
continues at TG-24 / T-125.

Dependencies point at lower task IDs only, so ascending ID order is a valid topological
order for the `implement` workflow's wave sort.

## Requirement ID resolution

Requirement links in task files climb four directory levels to
`define-requirements/FR/...` and `define-requirements/NFR/...`, which resolve to
`specs/define-requirements/` in this worktree. All 17 FR-SP and 12 NFR-SP documents are linked from at least one task;
the per-requirement map is in [plan.md](../plan.md).
