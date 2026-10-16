# TG-38 — Release Gate, Acceptance and Device Validation

> **Jira Epic:** Release Gate, Acceptance and Device Validation

## Description
The integration and evidence group: the release log-safety gate extended over the feature's new paths, the end-to-end acceptance sweep over the integrated tree (scoped suites, one full-suite run with the baseline named, the preservation audit), and the DV-1..6 device-validation protocol and record that is the feature's completion gate. Nothing ships from this group by itself; it is what makes the earlier groups' claims checkable.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-185](T-185-release-log-safety-gate-coverage.md) | Release log-surface gate coverage for the new chat paths | S | T-168, T-174, T-175, T-177 | HIGH |
| [T-186](T-186-end-to-end-acceptance-and-scoped-sweep.md) | End-to-end acceptance, scoped sweep and the one full-suite run | M | T-170, T-171, T-177, T-184, T-185 | HIGH |
| [T-187](T-187-dv-protocol-and-record.md) | DV-1..6 device-validation protocol and record (completion gate) | M | T-186 | HIGH |

## Group effort estimate
- Optimistic (full parallel): ~4.5 days
- Realistic (2 devs): ~3 days (plus the device session when it is scheduled)

## Group-wide gates and conventions
- Baseline honesty is the group's rule: pre-existing failures are named from the recorded baseline, new failures are fixed here, and no result is inferred from a different evidence class (a device item is not satisfied by a unit test).
- The full suite runs once, in this group, over the integrated tree; the scoped suites remain the per-unit gates and must all be green before the sweep.
- The release log gate (`ios/tools/check-release-log-safety.sh`) must exit zero over the integrated tree and is wired ahead of every test scope in the build — its exit code is gate evidence, not a suggestion.
- The DV record is structured for mechanical verification at the final sign-off and follows the house device-validation protocol convention; BLOCKED-with-reason is a legitimate terminal state, a fabricated pass is not.
